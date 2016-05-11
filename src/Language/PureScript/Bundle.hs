-----------------------------------------------------------------------------
--
-- Module      :  psc-bundle
-- Copyright   :  (c) Phil Freeman 2015
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- | Bundles compiled PureScript modules for the browser.
--
-- This module takes as input the individual generated modules from 'Language.PureScript.Make' and
-- performs dead code elimination, filters empty modules,
-- and generates the final Javascript bundle.
-----------------------------------------------------------------------------

{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Language.PureScript.Bundle (
     bundle
   , ModuleIdentifier(..)
   , moduleName
   , ModuleType(..)
   , ErrorMessage(..)
   , printErrorMessage
   , getExportedIdentifiers
) where

import Prelude ()
import Prelude.Compat

import Data.List (nub, stripPrefix)
import Data.Maybe (mapMaybe, catMaybes, fromMaybe)
import Data.Generics (everything, everywhere, mkQ, mkT)
import Data.Graph
import Data.Version (showVersion)

import qualified Data.Set as S

import Control.Monad
import Control.Monad.Error.Class
import Language.JavaScript.Parser.AST hiding (showStripped)
import Language.JavaScript.Parser
import Language.PureScript.BundleOpt
import Language.PureScript.BundleTypes

-- import Debug.Trace

import qualified Paths_purescript as Paths

-- | The type of error messages. We separate generation and rendering of errors using a data
-- type, in case we need to match on error types later.
data ErrorMessage
  = UnsupportedModulePath String
  | InvalidTopLevel
  | UnableToParseModule String
  | UnsupportedExport
  | ErrorInModule ModuleIdentifier ErrorMessage
  deriving (Show, Read)

-- | Prepare an error message for consumption by humans.
printErrorMessage :: ErrorMessage -> [String]
printErrorMessage (UnsupportedModulePath s) =
  [ "A CommonJS module has an unsupported name (" ++ show s ++ ")."
  , "The following file names are supported:"
  , "  1) index.js (psc native modules)"
  , "  2) foreign.js (psc foreign modules)"
  ]
printErrorMessage InvalidTopLevel =
  [ "Expected a list of source elements at the top level." ]
printErrorMessage (UnableToParseModule err) =
  [ "The module could not be parsed:"
  , err
  ]
printErrorMessage UnsupportedExport =
  [ "An export was unsupported. Exports can be defined in one of two ways: "
  , "  1) exports.name = ..."
  , "  2) exports = { ... }"
  ]
printErrorMessage (ErrorInModule mid e) =
  ("Error in module " ++ displayIdentifier mid ++ ":")
  : ""
  : map ("  " ++) (printErrorMessage e)
  where
  displayIdentifier (ModuleIdentifier name ty) =
    name ++ " (" ++ showModuleType ty ++ ")"

-- | Calculate the ModuleIdentifier which a require(...) statement imports.
checkImportPath :: Maybe FilePath -> String -> ModuleIdentifier -> S.Set String -> Either String ModuleIdentifier
checkImportPath _ "./foreign" m _ =
  Right (ModuleIdentifier (moduleName m) Foreign)
checkImportPath requirePath name _ names
  | Just name' <- stripPrefix (fromMaybe "../" requirePath) name
  , name' `S.member` names = Right (ModuleIdentifier name' Regular)
checkImportPath _ name _ _ = Left name

-- | Compute the dependencies of all elements in a module, and add them to the tree.
--
-- Members and exports can have dependencies. A dependency is of one of the following forms:
--
-- 1) module.name or member["name"]
--
--    where module was imported using
--
--    var module = require("Module.Name");
--
-- 2) name
--
--    where name is the name of a member defined in the current module.
withDeps :: Module -> Module
withDeps (Module modulePath es) = Module modulePath (map expandDeps es)
  where
  -- | Collects all modules which are imported, so that we can identify dependencies of the first type.
  imports :: [(String, ModuleIdentifier)]
  imports = mapMaybe toImport es
    where
    toImport :: ModuleElement -> Maybe (String, ModuleIdentifier)
    toImport (Require _ nm (Right mid)) = Just (nm, mid)
    toImport _ = Nothing

  -- | Collects all member names in scope, so that we can identify dependencies of the second type.
  boundNames :: [String]
  boundNames = mapMaybe toBoundName es
    where
    toBoundName :: ModuleElement -> Maybe String
    toBoundName (Member _ _ nm _ _) = Just nm
    toBoundName _ = Nothing

  -- | Calculate dependencies and add them to the current element.
  expandDeps :: ModuleElement -> ModuleElement
  expandDeps (Member n f nm decl _) = Member n f nm decl (nub $ dependencies modulePath decl)
  expandDeps (ExportsList exps) = ExportsList (map expand exps)
      where
      expand (ty, nm, n1, _) = (ty, nm, n1, nub (dependencies modulePath n1))
  expandDeps other = other

  dependencies :: ModuleIdentifier -> JSExpression -> [(ModuleIdentifier, String)]
  dependencies m = everything (++) (mkQ [] toReference)
    where
    toReference :: JSExpression -> [(ModuleIdentifier, String)]
    toReference (JSMemberDot mn _ nm)
      | JSIdentifier _ mn' <- mn
      , JSIdentifier _ nm' <- nm
      , Just mid <- lookup mn' imports
      = [(mid, nm')]
    toReference (JSMemberSquare mn _ nm _)
      | JSIdentifier _ mn' <- mn
      , Just nm' <- fromStringLiteral nm
      , Just mid <- lookup mn' imports
      = [(mid, nm')]
    toReference (JSIdentifier _ nm)
      | nm `elem` boundNames
      = [(m, nm)]
    toReference _ = []

-- String literals include the quote chars
fromStringLiteral :: JSExpression -> Maybe String
fromStringLiteral (JSStringLiteral _ str) = Just $ trimStringQuotes str
fromStringLiteral _ = Nothing

trimStringQuotes :: String -> String
trimStringQuotes str = reverse $ drop 1 $ reverse $ drop 1 $ str

commaList :: JSCommaList a -> [a]
commaList JSLNil = []
commaList (JSLOne x) = [x]
commaList (JSLCons l _ x) = commaList l ++ [x]

trailingCommaList :: JSCommaTrailingList a -> [a]
trailingCommaList (JSCTLComma l _) = commaList l
trailingCommaList (JSCTLNone l) = commaList l

-- | Attempt to create a Module from a Javascript AST.
--
-- Each type of module element is matched using pattern guards, and everything else is bundled into the
-- Other constructor.
toModule :: forall m. (MonadError ErrorMessage m) => Maybe FilePath -> S.Set String -> ModuleIdentifier -> JSAST -> m Module
toModule requirePath mids mid top
  | JSAstProgram smts _ <- top = Module mid <$> traverse toModuleElement smts
  | otherwise = err InvalidTopLevel
  where
  err = throwError . ErrorInModule mid

  toModuleElement :: JSStatement -> m ModuleElement
  toModuleElement stmt
    | Just (importName, importPath) <- matchRequire requirePath mids mid stmt
    = pure (Require stmt importName importPath)
  toModuleElement stmt
    | Just (exported, name, decl) <- matchMember stmt
    = pure (Member stmt exported name decl [])
  toModuleElement stmt
    | Just props <- matchExportsAssignment stmt
    = (ExportsList <$> traverse toExport (trailingCommaList props))
    where
      toExport :: JSObjectProperty -> m (ExportType, String, JSExpression, [Key])
      toExport (JSPropertyNameandValue name _ [val]) =
        (,,val,[]) <$> exportType val
                   <*> extractLabel' name
      toExport _ = err UnsupportedExport

      exportType :: JSExpression -> m ExportType
      exportType (JSMemberDot f _ _)
        | JSIdentifier _ "$foreign" <- f
        = pure ForeignReexport
      exportType (JSMemberSquare f _ _ _)
        | JSIdentifier _ "$foreign" <- f
        = pure ForeignReexport
      exportType (JSIdentifier _ s) = pure (RegularExport s)
      exportType _ = err UnsupportedExport

      extractLabel' = maybe (err UnsupportedExport) pure . extractLabel

  toModuleElement other = pure (Other other)

-- Get a list of all the exported identifiers from a foreign module.
--
-- TODO: what if we assign to exports.foo and then later assign to
-- module.exports (presumably overwriting exports.foo)?
getExportedIdentifiers :: (MonadError ErrorMessage m)
                          => String
                          -> JSAST
                          -> m [String]
getExportedIdentifiers mname top
  | JSAstProgram stmts _ <- top = concat <$> traverse go stmts
  | otherwise = err InvalidTopLevel
  where
  err = throwError . ErrorInModule (ModuleIdentifier mname Foreign)

  go stmt
    | Just props <- matchExportsAssignment stmt
    = traverse toIdent (trailingCommaList props)
    | Just (True, name, _) <- matchMember stmt
    = pure [name]
    | otherwise
    = pure []

  toIdent (JSPropertyNameandValue name _ [_]) =
    extractLabel' name
  toIdent _ =
    err UnsupportedExport

  extractLabel' = maybe (err UnsupportedExport) pure . extractLabel

-- Matches JS statements like this:
-- var ModuleName = require("file");
matchRequire :: Maybe FilePath
                -> S.Set String
                -> ModuleIdentifier
                -> JSStatement
                -> Maybe (String, Either String ModuleIdentifier)
matchRequire requirePath mids mid stmt
  | JSVariable _ jsInit _ <- stmt
  , [JSVarInitExpression var varInit] <- commaList jsInit
  , JSIdentifier _ importName <- var
  , JSVarInit _ jsInitEx <- varInit
  , JSMemberExpression req _ argsE _ <- jsInitEx
  , JSIdentifier _ "require" <- req
  , [ Just importPath ] <- map fromStringLiteral (commaList argsE)
  , importPath' <- checkImportPath requirePath importPath mid mids
  = Just (importName, importPath')
  | otherwise
  = Nothing

-- Matches JS member declarations.
matchMember :: JSStatement -> Maybe (Bool, String, JSExpression)
matchMember stmt
  -- var foo = expr;
  | JSVariable _ jsInit _ <- stmt
  , [JSVarInitExpression var varInit] <- commaList jsInit
  , JSIdentifier _ name <- var
  , JSVarInit _ decl <- varInit
  = Just (False, name, decl)
  -- exports.foo = expr; exports["foo"] = expr;
  | JSAssignStatement e (JSAssign _) decl _ <- stmt
  , Just name <- accessor e
  = Just (True, name, decl)
  | otherwise
  = Nothing
  where
  accessor :: JSExpression -> Maybe String
  accessor (JSMemberDot exports _ nm)
    | JSIdentifier _ "exports" <- exports
    , JSIdentifier _ name <- nm
    = Just name
  accessor (JSMemberSquare exports _ nm _)
    | JSIdentifier _ "exports" <- exports
    , Just name <- fromStringLiteral nm
    = Just name
  accessor _ = Nothing

-- Matches assignments to module.exports, like this:
-- module.exports = { ... }
matchExportsAssignment :: JSStatement -> Maybe JSObjectPropertyList
matchExportsAssignment stmt
  | JSAssignStatement e (JSAssign _) decl _ <- stmt
  , JSMemberDot module' _ exports <- e
  , JSIdentifier _ "module" <- module'
  , JSIdentifier _ "exports" <- exports
  , JSObjectLiteral _ props _ <- decl
  = Just props
  | otherwise
  = Nothing

extractLabel :: JSPropertyName -> Maybe String
extractLabel (JSPropertyString _ nm) = Just (trimStringQuotes nm)
extractLabel (JSPropertyIdent _ nm) = Just nm
extractLabel _ = Nothing

-- | Eliminate unused code based on the specified entry point set.
compile :: [Module] -> [ModuleIdentifier] -> [Module]
compile modules [] = modules
compile modules entryPoints = filteredModules
  where
  (graph, _, vertexFor) = graphFromEdges verts

  -- | The vertex set
  verts :: [(ModuleElement, Key, [Key])]
  verts = do
    Module mid els <- modules
    concatMap (toVertices mid) els
    where
    -- | Create a set of vertices for a module element.
    --
    -- Some special cases worth commenting on:
    --
    -- 1) Regular exports which simply export their own name do not count as dependencies.
    --    Regular exports which rename and reexport an operator do count, however.
    --
    -- 2) Require statements don't contribute towards dependencies, since they effectively get
    --    inlined wherever they are used inside other module elements.
    toVertices :: ModuleIdentifier -> ModuleElement -> [(ModuleElement, Key, [Key])]
    toVertices p m@(Member _ _ nm _ deps) = [(m, (p, nm), deps)]
    toVertices p m@(ExportsList exps) = mapMaybe toVertex exps
      where
      toVertex (ForeignReexport, nm, _, ks) = Just (m, (p, nm), ks)
      toVertex (RegularExport nm, nm1, _, ks) | nm /= nm1 = Just (m, (p, nm1), ks)
      toVertex _ = Nothing
    toVertices _ _ = []

  -- | The set of vertices whose connected components we are interested in keeping.
  entryPointVertices :: [Vertex]
  entryPointVertices = catMaybes $ do
    (_, k@(mid, _), _) <- verts
    guard $ mid `elem` entryPoints
    return (vertexFor k)

  -- | The set of vertices reachable from an entry point
  reachableSet :: S.Set Vertex
  reachableSet = S.fromList (concatMap (reachable graph) entryPointVertices)

  filteredModules :: [Module]
  filteredModules = map filterUsed modules
    where
    filterUsed :: Module -> Module
    filterUsed (Module mid ds) = Module mid (map filterExports (go ds))
      where
      go :: [ModuleElement] -> [ModuleElement]
      go [] = []
      go (d : rest)
        | not (isDeclUsed d) = go rest
        | otherwise = d : go rest

      -- | Filter out the exports for members which aren't used.
      filterExports :: ModuleElement -> ModuleElement
      filterExports (ExportsList exps) = ExportsList (filter (\(_, nm, _, _) -> isKeyUsed (mid, nm)) exps)
      filterExports me = me

      isDeclUsed :: ModuleElement -> Bool
      isDeclUsed (Member _ _ nm _ _) = isKeyUsed (mid, nm)
      isDeclUsed _ = True

      isKeyUsed :: Key -> Bool
      isKeyUsed k
        | Just me <- vertexFor k = me `S.member` reachableSet
        | otherwise = False

-- | Topologically sort the module dependency graph, so that when we generate code, modules can be
-- defined in the right order.
sortModules :: [Module] -> [Module]
sortModules modules = map (\v -> case nodeFor v of (n, _, _) -> n) (reverse (topSort graph))
  where
  (graph, nodeFor, _) = graphFromEdges $ do
    m@(Module mid els) <- modules
    return (m, mid, mapMaybe getKey els)

  getKey :: ModuleElement -> Maybe ModuleIdentifier
  getKey (Require _ _ (Right mi)) = Just mi
  getKey _ = Nothing

-- | A module is empty if it contains no exported members (in other words,
-- if the only things left after dead code elimination are module imports and
-- "other" foreign code).
--
-- If a module is empty, we don't want to generate code for it.
isModuleEmpty :: Module -> Bool
isModuleEmpty (Module _ els) = all isElementEmpty els
  where
  isElementEmpty :: ModuleElement -> Bool
  isElementEmpty (ExportsList exps) = null exps
  isElementEmpty Require{} = True
  isElementEmpty (Other _) = True
  isElementEmpty _ = False

-- | Generate code for a set of modules, including a call to main().
--
-- Modules get defined on the global PS object, as follows:
--
--     var PS = { };
--     (function(exports) {
--       ...
--     })(PS["Module.Name"] = PS["Module.Name"] || {});
--
-- In particular, a module and its foreign imports share the same namespace inside PS.
-- This saves us from having to generate unique names for a module and its foreign imports,
-- and is safe since a module shares a namespace with its foreign imports in PureScript as well
-- (so there is no way to have overlaps in code generated by psc).
codeGen :: Maybe String -- ^ main module
        -> String -- ^ namespace
        -> [Module] -- ^ input modules
        -> String
codeGen optionsMainModule optionsNamespace ms =  renderToString (JSAstProgram (prelude : concatMap moduleToJS ms ++ maybe [] runMain optionsMainModule) JSNoAnnot)
  where
  moduleToJS :: Module -> [JSStatement]
  moduleToJS (Module mn ds) = wrap (moduleName mn) (indent (concatMap declToJS ds))
    where
    declToJS :: ModuleElement -> [JSStatement]
    declToJS (Member n _ _ _ _) = [n]
    declToJS (Other n) = [n]
    declToJS (Require _ nm req) =
      [
        JSVariable lfsp
          (cList [
            JSVarInitExpression (JSIdentifier sp nm)
              (JSVarInit sp $ either require (moduleReference sp . moduleName) req )
          ]) (JSSemi JSNoAnnot)
      ]
    declToJS (ExportsList exps) = map toExport exps

      where
      toExport :: (ExportType, String, JSExpression, [Key]) -> JSStatement
      toExport (_, nm, val, _) =
        JSAssignStatement
          (JSMemberSquare (JSIdentifier lfsp "exports") JSNoAnnot
            (str nm) JSNoAnnot)
          (JSAssign sp)
          val
          (JSSemi JSNoAnnot)

  -- comma lists are reverse-consed
  cList :: [a] -> JSCommaList a
  cList [] = JSLNil
  cList [x] = JSLOne x
  cList l = go $ reverse l
    where
      go [x] = JSLOne x
      go (h:t)= JSLCons (go t) JSNoAnnot h
      go [] = error "Invalid case in comma-list"

  indent :: [JSStatement] -> [JSStatement]
  indent = everywhere (mkT squash)
    where
    squash JSNoAnnot = (JSAnnot (TokenPn 0 0 2) [])
    squash (JSAnnot pos ann) = JSAnnot (keepCol pos) (map splat ann)

    splat (CommentA pos s) = CommentA (keepCol pos) s
    splat (WhiteSpace pos w) = WhiteSpace (keepCol pos) w
    splat ann = ann

    keepCol (TokenPn _ _ c) = TokenPn 0 0 (if c >= 0 then c + 2 else 2)

  prelude :: JSStatement
  prelude = JSVariable (JSAnnot tokenPosnEmpty [ CommentA tokenPosnEmpty $ "// Generated by psc-bundle " ++ showVersion Paths.version
                                               , WhiteSpace tokenPosnEmpty "\n" ])
              (cList [
                JSVarInitExpression (JSIdentifier sp optionsNamespace)
                  (JSVarInit sp (emptyObj sp))
              ]) (JSSemi JSNoAnnot)

  require :: String -> JSExpression
  require mn =
    JSMemberExpression (JSIdentifier JSNoAnnot "require") JSNoAnnot (cList [ str mn ]) JSNoAnnot

  moduleReference :: JSAnnot -> String -> JSExpression
  moduleReference a mn =
    JSMemberSquare (JSIdentifier a optionsNamespace) JSNoAnnot
      (str mn) JSNoAnnot

  str :: String -> JSExpression
  str s = JSStringLiteral JSNoAnnot $ "\"" ++ s ++ "\""


  emptyObj :: JSAnnot -> JSExpression
  emptyObj a = JSObjectLiteral a (JSCTLNone JSLNil) JSNoAnnot

  wrap :: String -> [JSStatement] -> [JSStatement]
  wrap mn ds =
    [
    JSMethodCall (JSExpressionParen lf (JSFunctionExpression JSNoAnnot JSIdentNone JSNoAnnot
                                                (JSLOne (JSIdentName JSNoAnnot "exports")) JSNoAnnot
                                                (JSBlock sp (lfHead ds) lf)) -- \n not quite in right place
                                    JSNoAnnot)
                  JSNoAnnot
                  (JSLOne (JSAssignExpression (moduleReference JSNoAnnot mn) (JSAssign sp)
                            (JSExpressionBinary (moduleReference sp mn) (JSBinOpOr sp) (emptyObj sp))))
                  JSNoAnnot
                  (JSSemi JSNoAnnot)
    ]
    where
      lfHead (h:t) = (addAnn (WhiteSpace tokenPosnEmpty "\n  ") h) : t
      lfHead x = x

      addAnn :: CommentAnnotation -> JSStatement -> JSStatement
      addAnn a (JSExpressionStatement (JSStringLiteral ann s) _) =
        (JSExpressionStatement (JSStringLiteral (appendAnn a ann) s) (JSSemi JSNoAnnot))
      addAnn _ x = x

      appendAnn a JSNoAnnot = (JSAnnot tokenPosnEmpty [a])
      appendAnn a (JSAnnot _ anns) = JSAnnot tokenPosnEmpty (a:anns ++ [WhiteSpace tokenPosnEmpty "  "])

  runMain :: String -> [JSStatement]
  runMain mn =
    [JSMethodCall
      (JSMemberDot (moduleReference lf mn) JSNoAnnot
        (JSIdentifier JSNoAnnot "main"))
      JSNoAnnot (cList []) JSNoAnnot (JSSemi JSNoAnnot)]

  lf :: JSAnnot
  lf = JSAnnot tokenPosnEmpty [ WhiteSpace tokenPosnEmpty "\n" ]


  lfsp :: JSAnnot
  lfsp = JSAnnot tokenPosnEmpty [ WhiteSpace tokenPosnEmpty "\n  " ]

  sp :: JSAnnot
  sp = JSAnnot tokenPosnEmpty [ WhiteSpace tokenPosnEmpty " " ]

-- | The bundling function.
-- This function performs dead code elimination, filters empty modules
-- and generates and prints the final Javascript bundle.
bundle :: (Applicative m, MonadError ErrorMessage m)
     => [(ModuleIdentifier, String)] -- ^ The input modules.  Each module should be javascript rendered from 'Language.PureScript.Make' or @psc@.
     -> [ModuleIdentifier] -- ^ Entry points.  These module identifiers are used as the roots for dead-code elimination
     -> Maybe String -- ^ An optional main
     -> String -- ^ The namespace (e.g. PS).
     -> Maybe FilePath -- ^ The require path prefix
     -> Maybe String
     -> m String
bundle inputStrs entryPoints mainModule namespace requirePath optimize = do
  let shouldUncurry = case optimize of
                        Nothing -> False
                        Just "uncurry" -> True
                        Just "u" -> True
                        Just "all" -> True
                        Just "a" -> True
                        Just _ -> False
      secondRun = True
  input <- forM inputStrs $ \(ident, js) -> do
                ast <- either (throwError . ErrorInModule ident . UnableToParseModule) pure $ parse js (moduleName ident)
                return (ident, ast)

  let mids = S.fromList (map (moduleName . fst) input)

  modules <- traverse (fmap withDeps . uncurry (toModule requirePath mids)) input

  let compiled = compile modules entryPoints

  compiled' <- if shouldUncurry
                    then do
                        let modules' = uncurryFunc compiled entryPoints
                        if secondRun
                            then do
                                modules'' <- traverse (fmap withDeps . pure) modules' -- traverse and compile again
                                return (compile modules'' entryPoints)
                            else return modules'
                    else return compiled

  let sorted   = sortModules (filter (not . isModuleEmpty) compiled')

  return (codeGen mainModule namespace sorted)
