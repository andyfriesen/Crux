{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module Crux.Typecheck
    ( run
    ) where

import Control.Exception (try, ErrorCall (..))
import Crux.AST
import qualified Crux.MutableHashTable as HashTable
import Crux.Prelude
import Crux.Tokens (Pos (..))
import Crux.Typecheck.Env
import           Crux.Typecheck.Types
import           Crux.Typecheck.Unify
import qualified Data.HashMap.Strict   as HashMap
import qualified Data.Text             as Text
import           Prelude               hiding (String)
import           Text.Printf           (printf)
import qualified Crux.Error as Error
import Crux.Module.Types
import Crux.TypeVar

-- | Build up an environment for a case of a match block.
-- exprType is the type of the expression.  We unify this with the constructor of the pattern
-- TODO: wipe this out and replace it with ePatternBindings in Env
buildPatternEnv :: TypeVar -> Env -> RefutablePattern -> IO ()
buildPatternEnv exprType env = \case
    RPIrrefutable PWildcard -> do
        return ()

    RPIrrefutable (PBinding pname) -> do
        HashTable.insert pname (ValueReference (Local pname) LImmutable exprType) (eValueBindings env)

    RPConstructor cname cargs -> do
        HashTable.lookup cname (ePatternBindings env) >>= \case
            Just (PatternBinding def tyVars) -> do
                subst <- HashTable.new
                (ty', variants) <- instantiateUserType subst env def tyVars
                let [thisVariantParameters] = [tvParameters | TVariant{..} <- variants, tvName == cname]
                unify exprType ty'

                when (length thisVariantParameters /= length cargs) $
                    error $ printf "Pattern %s should specify %i args but got %i" (Text.unpack cname) (length thisVariantParameters) (length cargs)

                for_ (zip cargs thisVariantParameters) $ \(arg, vp) -> do
                    buildPatternEnv vp env arg
            _ -> error $ printf "Unbound constructor %s" (show cname)

lookupBinding :: Name -> Env -> IO (Maybe (ResolvedReference, LetMutability, TypeVar))
lookupBinding name Env{..} = do
    HashTable.lookup name eValueBindings >>= \case
        Just (ValueReference a b c) -> return $ Just (a, b, c)
        _ -> return $ Nothing

isLValue :: Env -> Expression ResolvedReference TypeVar -> IO Bool
isLValue env expr = case expr of
    EIdentifier _ name -> do
        l <- lookupBinding (resolvedReferenceName name) env
        return $ case l of
            Just (_, LMutable, _) -> True
            _ -> False
    ELookup _ lhs propName -> do
        lty' <- followTypeVar (edata lhs)
        case lty' of
            TRecord ref' -> followRecordTypeVar' ref' >>= \(ref, RecordType recordEData rows) -> do
                case lookupTypeRow propName rows of
                    Just (RMutable, _) ->
                        return True
                    Just (RQuantified, _) -> do
                        return False
                    Just (RImmutable, _) -> do
                        return False
                    Just (RFree, rowTy) -> do
                        -- Update this record field to be a mutable field
                        let newRow = TypeRow{trName=propName, trMut=RMutable, trTyVar=rowTy}
                        let newFields = newRow:[tr | tr <- rows, trName tr /= propName]

                        -- TODO: just unify this thing with a record with a mutable field
                        writeIORef ref $ RRecord $ RecordType recordEData newFields

                        return True
                    Nothing -> do
                        -- This should  be impossible because type inference should have either failed, or
                        -- caused this record type to include the field by now.
                        ltys <- showTypeVarIO lty'
                        error $ printf "Internal compiler error: calling isLValue on a nonexistent property %s of record %s" (show propName) ltys
            _ ->
                error "Internal compiler error: calling isLValue on a property lookup of a non-record type"
    _ -> return False

resolveTypeReference :: Pos -> Env -> UnresolvedReference -> IO TypeVar
resolveTypeReference pos env (UnqualifiedReference name) = do
    HashTable.lookup name (eTypeBindings env) >>= \case
        Just (TypeBinding _ t) -> return t
        Just (TypeAlias _ _ _) -> fail "TODO: resolveType implementation for TypeAlias"
        Nothing -> do
            tb <- readIORef $ eTypeBindings env
            throwIO $ ErrorCall $ "FATAL: Environment does not contain a " ++ show name ++ " type at: " ++ show pos ++ " " ++ (show $ HashMap.keys tb)
resolveTypeReference pos env (KnownReference moduleName name) = do
    if moduleName == eThisModule env then do
        resolveTypeReference pos env (UnqualifiedReference name)
    else do
        findExportedTypeByName env moduleName name >>= \case
            Just (_, tv) -> return tv
            Nothing -> fail "No exported type in module. TODO: this error message"

resolveValueReference :: Env -> UnresolvedReference -> IO (Maybe (ResolvedReference, LetMutability, TypeVar))
resolveValueReference env ref = case ref of
    UnqualifiedReference name -> do
        result <- HashTable.lookup name (eValueBindings env)
        return $ case result of
            Just (ValueReference rr mut t) -> Just (rr, mut, t)
            _ -> Nothing
    KnownReference moduleName name -> do
        findExportedValueByName env moduleName name >>= \case
            Just (rr, mutability, typevar) ->
                return $ Just (rr, mutability, typevar)
            Nothing -> fail $ printf "No exported %s in module %s" (show name) (Text.unpack $ printModuleName moduleName)

withPositionInformation :: forall a. Expression UnresolvedReference Pos -> IO a -> IO a
withPositionInformation expr a = catch a handle
  where
    handle :: TypeError () -> IO a
    handle e = throwIO $ fmap (\() -> edata expr) e

resolveArrayType :: Pos -> Env -> IO (TypeVar, TypeVar)
resolveArrayType pos env = do
    elementType <- freshType env
    arrayType <- resolveTypeReference pos env (UnqualifiedReference "Array")
    followTypeVar arrayType >>= \case
        TUserType td [_elementType] -> do
            let newArrayType = TUserType td [elementType]
            return (newArrayType, elementType)
        _ -> fail "Unexpected Array type"

resolveBooleanType :: Pos -> Env -> IO TypeVar
resolveBooleanType pos env = do
    resolveTypeReference pos env (KnownReference "prelude" "Boolean")

-- TODO: rename to checkNew or some other function that conveys "typecheck, but
-- I don't know or care what type you will be." and port all uses of check to it.
check :: Env -> Expression UnresolvedReference Pos -> IO (Expression ResolvedReference TypeVar)
check env expr = do
    newType <- freshType env
    checkExpecting newType env expr

checkExpecting :: TypeVar -> Env -> Expression UnresolvedReference Pos -> IO (Expression ResolvedReference TypeVar)
checkExpecting expectedType env expr = do
    e <- check' expectedType env expr
    unify (edata e) expectedType
    return e

check' :: TypeVar -> Env -> Expression UnresolvedReference Pos -> IO (Expression ResolvedReference TypeVar)
check' expectedType env expr = withPositionInformation expr $ case expr of
    EFun _ params retAnn body -> do
        valueBindings' <- HashTable.clone (eValueBindings env)

        -- If we know the expected function type, then use its type variables
        -- rather than make new ones.
        (paramTypes, returnType) <- followTypeVar expectedType >>= \case
            TFun paramTypes returnType -> do
                return (paramTypes, returnType)
            _ -> do
                paramTypes <- for params $ \_ -> do
                    freshType env
                returnType <- freshType env
                return (paramTypes, returnType)

        for_ (zip params paramTypes) $ \((p, pAnn), pt) -> do
            for_ pAnn $ \ann -> do
                annTy <- resolveTypeIdent env NewTypesAreQuantified ann
                unify pt annTy
            HashTable.insert p (ValueReference (Local p) LImmutable pt) valueBindings'

        let env' = env
                { eValueBindings=valueBindings'
                , eReturnType=Just returnType
                , eInLoop=False
                }

        for_ retAnn $ \ann -> do
            annTy <- resolveTypeIdent env NewTypesAreQuantified ann
            unify returnType annTy

        body' <- check env' body
        unify returnType $ edata body'

        let ty = TFun paramTypes returnType
        return $ EFun ty params retAnn body'

    -- Compiler intrinsics
    EApp _ (EIdentifier _ (UnqualifiedReference "_debug_type")) [arg] -> do
        arg' <- check env arg
        argType <- renderTypeVarIO $ edata arg'
        putStrLn $ "Debug Type: " ++ argType
        return arg'
    EApp _ (EIdentifier _ (UnqualifiedReference "_unsafe_js")) [ELiteral _ (LString txt)] -> do
        t <- freshType env
        return $ EIntrinsic t (IUnsafeJs txt)
    EApp _ (EIdentifier _ (UnqualifiedReference "_unsafe_js")) _ ->
        error "_unsafe_js takes just one string literal"

    EApp _ (EIdentifier _ (UnqualifiedReference "_unsafe_coerce")) [subExpr] -> do
        t <- freshType env
        subExpr' <- check env subExpr
        return $ EIntrinsic t (IUnsafeCoerce subExpr')
    EApp _ (EIdentifier _ (UnqualifiedReference "_unsafe_coerce")) _ ->
        error "_unsafe_coerce takes just one argument"

    EApp _ fn args -> do
        fn' <- check env fn
        followTypeVar (edata fn') >>= \case
            -- in the case that the type of the function is known, we propagate
            -- the known argument types into the environment so tdnr works
            TFun argTypes resultType -> do
                args' <- for (zip argTypes args) $ \(argType, arg) -> do
                    checkExpecting argType env arg

                let appTy = TFun (map edata args') resultType
                unify (edata fn') appTy

                return $ EApp resultType fn' args'
            _ -> do
                args' <- for args $ check env
                result <- freshType env
                let ty = TFun (map edata args') result
                unify (edata fn') ty
                return $ EApp result fn' args'

    EIntrinsic {} -> do
        error "Unexpected: EIntrinsic encountered during typechecking"

    ELookup _ lhs propName -> do
        let valueLookup = do
                -- if lhs is ident and in bindings, then go go go
                -- else turn into QualifiedReference and go go go
                lhs' <- check env lhs
                ty <- freshType env
                row <- freshRowVariable env
                rec <- newIORef $ RRecord $ RecordType (RecordFree row) [TypeRow{trName=propName, trMut=RFree, trTyVar=ty}]
                unify (edata lhs') $ TRecord rec
                return $ ELookup ty lhs' propName
        case lhs of
            EIdentifier _ (UnqualifiedReference name) -> do
                HashTable.lookup name (eValueBindings env) >>= \case
                    Just (ModuleReference mn) -> do
                        findExportedValueByName env mn propName >>= \case
                            -- TODO: where does mutability go?
                            Just (resolvedRef, _mutability, typeVar) -> do
                                return $ EIdentifier typeVar resolvedRef
                            Nothing -> do
                                throwIO $ ModuleReferenceError () mn propName
                    _ -> valueLookup
            _ -> valueLookup

    EMatch _ matchExpr cases -> do
        resultType <- freshType env

        matchExpr' <- check env matchExpr

        cases' <- for cases $ \(Case patt caseExpr) -> do
            env' <- childEnv env
            buildPatternEnv (edata matchExpr') env' patt
            caseExpr' <- check env' caseExpr
            unify resultType (edata caseExpr')
            return $ Case patt caseExpr'

        return $ EMatch resultType matchExpr' cases'

    ELet _ mut pat maybeAnnot expr' -> do
        ty <- freshType env
        expr'' <- check env expr'
        case pat of
            PWildcard -> do
                return ()
            PBinding name -> do
                HashTable.insert name (ValueReference (Local name) mut ty) (eValueBindings env)
        unify ty (edata expr'')
        for_ maybeAnnot $ \annotation -> do
            annotTy <- resolveTypeIdent env NewTypesAreQuantified annotation
            unify ty annotTy

        let unitTy = TPrimitive Unit
        return $ ELet unitTy mut pat maybeAnnot expr''

    EAssign _ lhs rhs -> do
        lhs' <- check env lhs
        rhs' <- check env rhs

        unify (edata lhs') (edata rhs')

        islvalue <- isLValue env lhs'
        when (not islvalue) $ do
            throwIO $ NotAnLVar () $ show lhs

        let unitType = TPrimitive Unit

        return $ EAssign unitType lhs' rhs'

    ELiteral _ lit -> do
        let litType = case lit of
                LInteger _ -> TPrimitive Number
                LString _ -> TPrimitive String
                LUnit -> TPrimitive Unit
        return $ ELiteral litType lit

    EArrayLiteral _ elements -> do
        (arrayType, elementType) <- resolveArrayType (edata expr) env
        elements' <- for elements $ \element -> do
            elementExpr <- check env element
            unify elementType (edata elementExpr)
            return elementExpr
        return $ EArrayLiteral arrayType elements'

    ERecordLiteral _ fields -> do
        fields' <- for (HashMap.toList fields) $ \(name, fieldExpr) -> do
            ty <- freshType env
            fieldExpr' <- check env fieldExpr
            unify ty (edata fieldExpr')
            return (name, fieldExpr')

        let fieldTypes = map (\(name, ex) -> TypeRow{trName=name, trMut=RFree, trTyVar=edata ex}) fields'

        rec <- newIORef $ RRecord $ RecordType RecordClose fieldTypes
        let recordTy = TRecord rec
        return $ ERecordLiteral recordTy (HashMap.fromList fields')

    EIdentifier _ (UnqualifiedReference "_unsafe_js") ->
        throwIO $ IntrinsicError () "Intrinsic _unsafe_js is not a value"
    EIdentifier _ (UnqualifiedReference "_unsafe_coerce") ->
        error "Intrinsic _unsafe_coerce is not a value"
    EIdentifier _pos txt -> do
        (rr, tyref) <- do
            resolveValueReference env txt >>= \case
                Just (a@(Local _), _mutability, b) -> do
                    -- Don't instantiate locals.  Let generalization is tricky.
                    return (a, b)
                Just (a, _mutability, b) -> do
                    b' <- instantiate env b
                    return (a, b')
                Nothing ->
                    throwIO $ UnboundSymbol () txt

        return $ EIdentifier tyref rr
    ESemi _ lhs rhs -> do
        lhs' <- check env lhs
        rhs' <- check env rhs
        return $ ESemi (edata rhs') lhs' rhs'

    EMethodApp pos lhs methodName args -> do
        -- lhs must be typechecked so that, if it has a concrete type, we know
        -- the location of that type.
        lhs' <- check env lhs
        moduleName <- followTypeVar (edata lhs') >>= \case
            TUserType TUserTypeDef{..} _ -> do
                return tuModuleName
            TPrimitive _ -> do
                return "prelude"
            _ -> do
                ts <- showTypeVarIO $ edata lhs'
                throwIO $ TdnrLhsTypeUnknown () ts

        check env $ EApp
            pos
            (EIdentifier pos $ KnownReference moduleName methodName)
            (lhs : args)

    -- TEMP: For now, intrinsics are too polymorphic.
    -- Arithmetic operators like + and - have type (a, a) -> a
    -- Relational operators like <= and != have type (a, a) -> Bool
    EBinIntrinsic _ bi lhs rhs -> do
        lhs' <- check env lhs
        rhs' <- check env rhs

        if | isArithmeticOp bi -> do
                unify (edata lhs') (edata rhs')
                return $ EBinIntrinsic (edata lhs') bi lhs' rhs'
           | isRelationalOp bi -> do
                unify (edata lhs') (edata rhs')
                booleanType <- resolveBooleanType (edata expr) env
                return $ EBinIntrinsic booleanType bi lhs' rhs'
           | isBooleanOp bi -> do
                booleanType <- resolveBooleanType (edata lhs) env
                unify (edata lhs') booleanType
                unify (edata rhs') booleanType
                return $ EBinIntrinsic booleanType bi lhs' rhs'
           | otherwise ->
                error "This should be impossible: Check EBinIntrinsic"

    EIfThenElse _ condition ifTrue ifFalse -> do
        booleanType <- resolveBooleanType (edata expr) env

        condition' <- check env condition
        unify booleanType (edata condition')
        ifTrue' <- check env ifTrue
        ifFalse' <- check env ifFalse

        unify (edata ifTrue') (edata ifFalse')

        return $ EIfThenElse (edata ifTrue') condition' ifTrue' ifFalse'

    EWhile _ cond body -> do
        booleanType <- resolveBooleanType (edata expr) env
        let unitType = TPrimitive Unit

        condition' <- check env cond
        unify booleanType (edata condition')

        let env' = env { eInLoop = True }
        body' <- check env' body
        unify unitType (edata body')

        return $ EWhile unitType condition' body'

    EFor pos name over body -> do
        let unitType = TPrimitive Unit

        (arrayType, iteratorType) <- resolveArrayType pos env
        over' <- checkExpecting arrayType env over

        bindings' <- HashTable.clone (eValueBindings env)
        HashTable.insert name (ValueReference (Local name) LImmutable iteratorType) bindings'

        let env' = env { eValueBindings = bindings', eInLoop = True }
        body' <- check env' body
        unify unitType (edata body')

        return $ EFor unitType name over' body'

    EReturn _ rv -> do
        rv' <- check env rv
        case eReturnType env of
            Nothing ->
                error "Cannot return outside of functions"
            Just rt -> do
                unify rt $ edata rv'
                retTy <- freshType env
                return $ EReturn retTy rv'

    EBreak _ -> do
        when (not $ eInLoop env) $
            error "Cannot use 'break' outside of a loop"
        t <- freshType env
        return $ EBreak t

-- Phase 2a
registerJSFFIDecl :: Env -> Declaration UnresolvedReference Pos -> IO ()
registerJSFFIDecl env (Declaration _export _pos decl) = case decl of
    DDeclare {} -> return ()
    DLet {} -> return ()
    DFun {} -> return()

    DData {} -> return ()
    DJSData _pos name moduleName variants -> do
        -- jsffi data never has type parameters, so we can just blast through the whole thing in one pass
        variants' <- for variants $ \(JSVariant variantName _value) -> do
            let tvParameters = []
            let tvName = variantName
            return TVariant{..}

        let typeDef = TUserTypeDef
                { tuName = name
                , tuModuleName = moduleName
                , tuParameters = []
                , tuVariants = variants'
                }
        let userType = TUserType typeDef []
        HashTable.insert name (TypeBinding (Local name) userType) (eTypeBindings env)

        for_ variants $ \(JSVariant variantName _value) -> do
            HashTable.insert variantName (ValueReference (Local variantName) LImmutable userType) (eValueBindings env)
            HashTable.insert variantName (PatternBinding typeDef []) (ePatternBindings env)
        return ()
    DTypeAlias {} -> return ()

checkDecl :: Env -> Declaration UnresolvedReference Pos -> IO (Declaration ResolvedReference TypeVar)
checkDecl env (Declaration export pos decl) = fmap (Declaration export pos) $ case decl of

    {- VALUE DEFINITIONS -}

    DDeclare _pos name typeIdent -> do
        ty <- resolveTypeIdent env NewTypesAreQuantified typeIdent
        HashTable.insert name (ValueReference (Ambient name) LImmutable ty) (eValueBindings env)
        return $ DDeclare ty name typeIdent
    DLet pos' mut pat maybeAnnot expr ->
        let fakeExpr = ELet pos' mut pat maybeAnnot expr
        in withPositionInformation fakeExpr $ do
            env' <- childEnv env
            ty <- freshType env'
            for_ maybeAnnot $ \annotation -> do
                annotTy <- resolveTypeIdent env' NewTypesAreQuantified annotation
                unify ty annotTy

            expr' <- check env' expr
            unify ty (edata expr')

            case pat of
                PWildcard -> do
                    return ()
                PBinding name -> do
                    HashTable.insert name (ValueReference (ThisModule name) mut ty) (eValueBindings env)
            quantify ty
            return $ DLet (edata expr') mut pat maybeAnnot expr'
    DFun pos' name args returnAnn body ->
        let expr = EFun pos' args returnAnn body
        in withPositionInformation expr $ do
            ty <- freshType env
            HashTable.insert name (ValueReference (ThisModule name) LImmutable ty) (eValueBindings env)
            expr'@(EFun _ _ _ body') <- check env expr
            unify (edata expr') ty
            quantify ty
            return $ DFun (edata expr') name args returnAnn body'

    {- TYPE DEFINITIONS -}

    DData _pos name moduleName typeParameters variants -> do
        -- TODO: add an internal compiler error if the name is not in bindings
        -- TODO: error when a name is inserted into type bindings twice at top level
        -- TODO: is there a better way to carry this information from environment
        -- setup through type checking of decls?
        (Just (TypeBinding _ typeVar)) <- HashTable.lookup name (eTypeBindings env)

        typedVariants <- for variants $ \(Variant _pos vname vparameters) -> do
            (Just (ValueReference _rr _mut ctorType)) <- HashTable.lookup vname (eValueBindings env)
            return $ Variant ctorType vname vparameters

        return $ DData typeVar name moduleName typeParameters typedVariants

    DJSData _pos name moduleName variants -> do
        -- TODO: add an internal compiler error if the name is not in bindings
        -- TODO: error when a name is inserted into type bindings twice at top level
        -- TODO: is there a better way to carry this information from environment
        -- setup through type checking of decls?
        (Just (TypeBinding _ typeVar)) <- HashTable.lookup name (eTypeBindings env)
        return $ DJSData typeVar name moduleName variants
    DTypeAlias name typeVars ident -> do
        return $ DTypeAlias name typeVars ident

run :: HashMap ModuleName LoadedModule -> Module UnresolvedReference Pos -> ModuleName -> IO (Either Error.Error LoadedModule)
run loadedModules thisModule thisModuleName = runEitherT $ do
    {-
    populate environment:
        eTypeBindings
        eValueBindings
        ePatternBindings

    phase 1:
        register all qualified imports
        register all unqualified imports

    phase 2:
      a. register all jsffi types (both data constructors and patterns)
      b. register all data types (and only the types)
      c. register all type aliases
      d. register all data type constructors and patterns (using same qvars from before)

    phase 3:
        type check all values in order
    -}

    -- Phase 1
    env <- EitherT $ (try $ buildTypeEnvironment thisModuleName loadedModules (mImports thisModule)) >>= \case
        Left err -> return $ Left $ Error.TypeError err
        Right result -> return result

    -- Phase 2a
    lift $ for_ (mDecls thisModule) $ \decl -> do
        registerJSFFIDecl env decl

    result <- liftIO $ try $ addThisModuleDataDeclsToEnvironment env thisModule [decl | Declaration _ _ decl <- mDecls thisModule] ThisModule
    case result of
        Left err -> left $ Error.TypeError err
        Right d -> return d

    decls <- for (mDecls thisModule) $ \decl -> do
        (lift $ try $ checkDecl env decl) >>= \case
            Left err -> left $ Error.TypeError err
            Right d -> return d
    return $ thisModule{ mDecls = decls }
