{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Crux.Typecheck where

import           Control.Monad         (forM, forM_, when)
import           Crux.AST
import           Crux.Intrinsic        (Intrinsic(..))
import qualified Crux.Intrinsic        as Intrinsic
import qualified Crux.MutableHashTable as HashTable
import           Data.HashMap.Strict   (HashMap)
import qualified Data.HashMap.Strict   as HashMap
import           Data.IORef            (IORef, readIORef, writeIORef)
import qualified Data.IORef            as IORef
import           Data.List             (foldl')
import           Data.Text             (Text)
import           Prelude               hiding (String)
import           Text.Printf           (printf)

data Env = Env
    { eNextTypeIndex :: IORef Int
    , eBindings      :: IORef (HashMap Text TypeVar)
    , eTypeBindings  :: HashMap Text TypeVar
    , eIsTopLevel    :: Bool
    }

showTypeVarIO :: TypeVar -> IO [Char]
showTypeVarIO tvar = case tvar of
    TVar i o -> do
        o' <- readIORef o
        os <- case o' of
            Unbound -> return "Unbound"
            Link x -> showTypeVarIO x
        return $ "TVar " ++ show i ++ " " ++ os
    TQuant i ->
        return $ "TQuant " ++ show i
    TFun args ret -> do
        as <- forM args showTypeVarIO
        rs <- showTypeVarIO ret
        return $ "TFun " ++ show as  ++ " -> " ++ rs
    TType ty ->
        return $ "TType " ++ show ty

newEnv :: IO Env
newEnv = do
    eNextTypeIndex <- IORef.newIORef 0
    eBindings <- IORef.newIORef HashMap.empty
    let eTypeBindings = HashMap.empty
    let eIsTopLevel = True
    return Env {..}

childEnv :: Env -> IO Env
childEnv env = do
    bindings' <- HashTable.clone (eBindings env)
    return env{eBindings=bindings', eIsTopLevel=False}

freshType :: Env -> IO TypeVar
freshType Env{eNextTypeIndex} = do
    IORef.modifyIORef' eNextTypeIndex (+1)
    index <- IORef.readIORef eNextTypeIndex
    link <- IORef.newIORef Unbound
    return $ TVar index link

typeFromConstructor :: Env -> Name -> Maybe (Type, Variant)
typeFromConstructor env cname =
    let fold acc ty = case (acc, ty) of
            (Just a, _) -> Just a
            (Nothing, TType ut@(UserType _ variants)) ->
                case [v | v@(Variant vname _) <- variants, vname == cname] of
                    [v] -> Just (ut, v)
                    [] -> Nothing
                    _ -> error "This should never happen: Type has multiple variants with the same constructor name"
            _ -> Nothing
    in foldl' fold Nothing (HashMap.elems $ eTypeBindings env)

-- | Build up an environment for a case of a match block.
-- exprType is the type of the expression.  We unify this with the constructor of the pattern
buildPatternEnv :: TypeVar -> Env -> Pattern2 -> IO ()
buildPatternEnv exprType env patt = case patt of
    PPlaceholder pname -> do
        HashTable.insert pname exprType (eBindings env)

    PConstructor cname cargs -> do
        case typeFromConstructor env cname of
            Just (ty@(UserType {}), variant) -> do
                unify exprType (TType ty)
                let Variant{vparameters} = variant

                when (length vparameters /= length cargs) $
                    error $ printf "Pattern should specify %i args but got %i" (length vparameters) (length cargs)

                forM_ (zip cargs vparameters) $ \(arg, vp) -> do
                    case HashMap.lookup vp (eTypeBindings env) of
                        Just vty ->
                            buildPatternEnv vty env arg
                        _ -> error $ printf "Should never happen: Sum type %s has data element of nonexistent type %s"
            _ -> error $ printf "Unbound constructor %s" (show cname)

check :: Env -> Expression a -> IO (Expression TypeVar)
check env expr = case expr of
    EBlock _ exprs -> do
        bindings' <- HashTable.clone (eBindings env)
        let env' = env{eBindings=bindings'}
        case exprs of
            [] -> do
                return $ EBlock (TType Unit) []
            _ -> do
                exprs' <- forM exprs (check env')
                return $ EBlock (edata $ last exprs') exprs'
    EFun _ params exprs -> do
        bindings' <- HashTable.clone (eBindings env)
        paramTypes <- forM params $ \param -> do
            paramType <- freshType env
            HashTable.insert param paramType bindings'
            return paramType

        case exprs of
            [] -> do
                return $ EFun (TFun paramTypes (TType Unit)) params []
            _ -> do
                let env' = env{eBindings=bindings', eIsTopLevel=False}
                exprs' <- forM exprs (check env')
                return $ EFun (TFun paramTypes (edata $ last exprs')) params exprs'

    EApp _ lhs rhs -> do
        lhs' <- check env lhs
        rhs' <- check env rhs
        result <- freshType env
        unify (edata lhs') (TFun [edata rhs'] result)
        return $ EApp result lhs' rhs'

    EMatch _ matchExpr cases -> do
        resultType <- freshType env

        matchExpr' <- check env matchExpr

        cases' <- forM cases $ \(Case patt caseExpr) -> do
            env' <- childEnv env
            buildPatternEnv (edata matchExpr') env' patt
            caseExpr' <- check env' caseExpr
            unify resultType (edata caseExpr')
            return $ Case patt caseExpr'

        return $ EMatch resultType matchExpr' cases'

    ELet _ name expr' -> do
        ty <- freshType env
        HashTable.insert name ty (eBindings env)
        expr'' <- check env expr'
        unify ty (edata expr'')
        when (eIsTopLevel env) $ do
            quantify ty
        return $ ELet ty name expr''

    EPrint _ expr' -> do
        expr'' <- check env expr'
        return $ EPrint (TType Unit) expr''
    EToString _ expr' -> do
        expr'' <- check env expr'
        return $ EToString (TType String) expr''
    ELiteral _ (LInteger i) -> do
        return $ ELiteral (TType Number) (LInteger i)
    ELiteral _ (LString s) -> do
        return $ ELiteral (TType String) (LString s)
    ELiteral _ LUnit -> do
        return $ ELiteral (TType Unit) LUnit
    EIdentifier _ txt -> do
        result <- HashTable.lookup txt (eBindings env)
        case result of
            Nothing ->
                error $ "Unbound symbol " ++ show txt
            Just tyref -> do
                tyref' <- instantiate env tyref
                return $ EIdentifier tyref' txt
    ESemi _ lhs rhs -> do
        lhs' <- check env lhs
        rhs' <- check env rhs
        return $ ESemi (edata rhs') lhs' rhs'

quantify :: TypeVar -> IO ()
quantify ty = do
    case ty of
        TVar i tv -> do
            tv' <- readIORef tv
            case tv' of
                Unbound -> do
                    writeIORef tv (Link $ TQuant i)
                Link t' ->
                    quantify t'
        TFun [param] ret -> do
            quantify param
            quantify ret
        _ ->
            return ()

instantiate :: Env -> TypeVar -> IO TypeVar
instantiate env t =
    let go ty subst = case ty of
            TQuant name -> do
                case lookup name (subst :: [(Int, TypeVar)]) of
                    Just v -> return (v, subst)
                    Nothing -> do
                        tv <- freshType env
                        return (tv, (name, tv):subst)
            TVar _ tv -> do
                vl <- readIORef tv
                case vl of
                    Link tv' -> go tv' subst
                    Unbound -> return (ty, subst)
            TFun [param] ret -> do
                (ty1, subst') <- go param subst
                (ty2, subst'') <- go ret subst'
                return (TFun [ty1] ty2, subst'')
            _ -> return (ty, subst)
    in fmap fst (go t [])

flattenTypeVar :: TypeVar -> IO ImmutableTypeVar
flattenTypeVar tv = case tv of
        TVar i ior -> do
            t <- IORef.readIORef ior
            case t of
                Unbound ->
                    return $ IVar i Unbound
                Link tv' -> do
                    flattenTypeVar tv'
        TQuant i ->
            return $ IQuant i
        TFun args body -> do
            args' <- forM args flattenTypeVar
            body' <- flattenTypeVar body
            return $ IFun args' body'
        TType t ->
            return $ IType t

flatten :: Expression TypeVar -> IO (Expression ImmutableTypeVar)
flatten expr = case expr of
    EBlock td exprs -> do
        td' <- flattenTypeVar td
        exprs' <- forM exprs flatten
        return $ EBlock td' exprs'
    EFun td params exprs -> do
        td' <- flattenTypeVar td
        exprs' <- forM exprs flatten
        return $ EFun td' params exprs'
    EApp td lhs rhs -> do
        td' <- flattenTypeVar td
        lhs' <- flatten lhs
        rhs' <- flatten rhs
        return $ EApp td' lhs' rhs'
    EMatch td matchExpr cases -> do
        td' <- flattenTypeVar td
        expr' <- flatten matchExpr
        cases' <- forM cases $ \(Case pattern subExpr) ->
            fmap (Case pattern) (flatten subExpr)
        return $ EMatch td' expr' cases'
    ELet td name expr' -> do
        td' <- flattenTypeVar td
        expr'' <- flatten expr'
        return $ ELet td' name expr''
    EPrint td expr' -> do
        td' <- flattenTypeVar td
        expr'' <- flatten expr'
        return $ EPrint td' expr''
    EToString td expr' -> do
        td' <- flattenTypeVar td
        expr'' <- flatten expr'
        return $ EToString td' expr''
    ELiteral td lit -> do
        td' <- flattenTypeVar td
        return $ ELiteral td' lit
    EIdentifier td i -> do
        td' <- flattenTypeVar td
        return $ EIdentifier td' i
    ESemi td lhs rhs -> do
        td' <- flattenTypeVar td
        lhs' <- flatten lhs
        rhs' <- flatten rhs
        return $ ESemi td' lhs' rhs'

flattenDecl :: Declaration TypeVar -> IO (Declaration ImmutableTypeVar)
flattenDecl decl = case decl of
    DData name variants ->
        return $ DData name variants
    DLet ty name expr -> do
        ty' <- flattenTypeVar ty
        expr' <- flatten expr
        return $ DLet ty' name expr'

unify :: TypeVar -> TypeVar -> IO ()
unify a b = case (a, b) of
        (TVar _ ar, _) -> do
            a' <- readIORef ar
            case a' of
                Unbound -> do
                    occurs ar b
                    writeIORef ar (Link b)
                Link a'' ->
                    unify a'' b

        (_, TVar {}) -> do
            unify b a

        (TType aType, TType bType)
            | aType == bType ->
                return ()
            | otherwise -> do
                error ("unification failure: " ++ (show (aType, bType)))

        (TFun aa ar, TFun ba br) -> do
            forM_ (zip aa ba) (uncurry unify)
            unify ar br

        (TFun {}, TType {}) -> do
            lt <- showTypeVarIO a
            rt <- showTypeVarIO b
            error $ "Unification failure: " ++ (show (lt, rt))
        (TType {}, TFun {}) -> do
            lt <- showTypeVarIO a
            rt <- showTypeVarIO b
            error $ "Unification failure: " ++ (show (lt, rt))

        -- These should never happen: Quantified type variables should be instantiated before we get here.
        (TQuant {}, _) ->
            error "Internal error: QVar made it to unify"
        (_, TQuant {}) ->
            error "Internal error: QVar made it to unify"

occurs :: IORef (VarLink TypeVar) -> TypeVar -> IO ()
occurs tvr ty = case ty of
    TVar _ ty'
        | tvr == ty' -> error "Occurs check"
        | otherwise -> do
            ty'' <- readIORef ty'
            case ty'' of
                Link ty''' -> occurs tvr ty'''
                _ -> return ()
    TFun [arg] ret -> do
        occurs tvr arg
        occurs tvr ret
    _ ->
        return ()

checkDecl :: Env -> Declaration a -> IO (Declaration TypeVar)
checkDecl env decl = case decl of
    DData name variants -> return $ DData name variants
    DLet _ name expr -> do
        expr' <- check env expr
        HashTable.insert name (edata expr') (eBindings env)
        return $ DLet (edata expr') name expr'

buildTypeEnvironment :: [Declaration a] -> IO Env
buildTypeEnvironment decls = do
    env <- newEnv
    typeEnv <- IORef.newIORef $ HashMap.fromList
        [ ("Number", TType Number)
        , ("Unit", TType Unit)
        , ("String", TType String)
        ]

    forM_ decls $ \decl -> case decl of
        DData name variants -> do
            let userType = TType $ UserType name variants
            IORef.modifyIORef' typeEnv (HashMap.insert name userType)
        _ -> return ()

    te <- IORef.readIORef typeEnv

    let computeVariantType ty name argTypeNames = case argTypeNames of
            [] -> ty
            (x:xs) -> case HashMap.lookup x te of
                Nothing -> error $ "Constructor " ++ (show name) ++ " variant uses undefined type " ++ (show x)
                Just t -> TFun [t] (computeVariantType ty name xs)

    forM_ (HashMap.toList Intrinsic.intrinsics) $ \(name, intrin) -> do
        let Intrinsic{..} = intrin
        HashTable.insert name iType (eBindings env)

    forM_ decls $ \decl -> case decl of
        DData name variants -> do
            let Just userType = HashMap.lookup name te
            forM_ variants $ \(Variant vname vdata) -> do
                let ctorType = computeVariantType userType vname vdata
                HashTable.insert vname ctorType (eBindings env)
        _ -> return ()

    return env{eTypeBindings=te}

run :: [Declaration a] -> IO [Declaration TypeVar]
run decls = do
    env <- buildTypeEnvironment decls
    forM decls (checkDecl env)
