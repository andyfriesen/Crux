{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TupleSections #-}

module Crux.Gen
    ( Value(..)
    , Output(..)
    , Instruction(..)
    , DeclarationType(..)
    , Declaration(..)
    , Module
    , Program
    , generateModule
    , generateProgram
    ) where

import Crux.Prelude
import qualified Crux.AST as AST
import Control.Monad.Writer.Lazy (WriterT, runWriterT, tell)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe (MaybeT(..), runMaybeT)
import Data.Graph (graphFromEdges, topSort)
import qualified Data.HashMap.Strict as HashMap

type Name = Text
data Output = Binding AST.ResolvedReference | Temporary Int | OutputProperty Output Name
    deriving (Show, Eq)
data Value
    = Reference Output
    | Literal AST.Literal
    | FunctionLiteral [Name] [Instruction]
    | ArrayLiteral [Value]
    | RecordLiteral (HashMap Name Value)
    deriving (Show, Eq)
type Input = Value

data Instruction
    -- binding
    = EmptyLet Output
    | LetBinding Name Input

    -- operations
    | Assign Output Input
    | BinIntrinsic Output (AST.BinIntrinsic) Input Input
    | Intrinsic Output (AST.Intrinsic Input)
    | Call Output Input [Input]
    | MethodCall Output Input Name [Input]
    | Lookup Output Input Name

    -- control flow
    | Return Input
    | Match Input [(AST.Pattern, [Instruction])]
    | If Input [Instruction] [Instruction]
    | Loop [Instruction]
    | Break
    deriving (Show, Eq)

type Env = IORef Int

data DeclarationType
    = DData Name [AST.Variant]
    | DJSData Name [AST.JSVariant]
    | DFun Name [Name] [Instruction]
    | DLet Name [Instruction]
    deriving (Show, Eq)

data Declaration = Declaration AST.ExportFlag DeclarationType
    deriving (Show, Eq)

type Program = [(AST.ModuleName, Module)] -- topologically sorted
type Module = [Declaration]

newTempOutput :: Env -> IO Output
newTempOutput env = do
    value <- readIORef env
    writeIORef env (value + 1)
    return $ Temporary value

type DeclarationWriter a = WriterT [Declaration] IO a

writeDeclaration :: Declaration -> DeclarationWriter ()
writeDeclaration d = tell [d]

type InstructionWriter a = WriterT [Instruction] IO a

writeInstruction :: Instruction -> InstructionWriter ()
writeInstruction i = tell [i]

newInstruction :: Env -> (Output -> Instruction) -> InstructionWriter Value
newInstruction env instr = do
    output <- lift $ newTempOutput env
    writeInstruction $ instr output
    return $ Reference output

both :: Maybe a -> Maybe b -> Maybe (a, b)
both (Just x) (Just y) = Just (x, y)
both _ _ = Nothing

generate :: Show t => Env -> AST.Expression AST.ResolvedReference t -> InstructionWriter (Maybe Value)
generate env expr = case expr of
    AST.ELet _ _mut name _ v -> do
        v' <- generate env v
        for v' $ \v'' -> do
            writeInstruction $ LetBinding name v''
            return $ Literal AST.LUnit

    AST.EFun _ params _retAnn body -> do
        body' <- subBlockWithReturn env body
        return $ Just $ FunctionLiteral (map fst params) body'

    AST.ELookup _ value propertyName -> do
        v <- generate env value
        for v $ \v' -> do
            newInstruction env $ \output -> Lookup output v' propertyName

    AST.EApp _ (AST.ELookup _ this methodName) args -> do
        this' <- generate env this
        args' <- runMaybeT $ mapM (MaybeT . generate env) args
        for (both this' args') $ \(this'', args'') -> do
            newInstruction env $ \output -> MethodCall output this'' methodName args''

    AST.EApp _ fn args -> do
        fn' <- generate env fn
        args' <- runMaybeT $ mapM (MaybeT . generate env) args
        for (both fn' args') $ \(fn'', args'') -> do
            newInstruction env $ \output -> Call output fn'' args''

    AST.EAssign _ (AST.ELookup _ lhs propName) rhs -> do
        lhs' <- generate env lhs
        rhs' <- generate env rhs
        for (both lhs' rhs') $ \(Reference lhs'', rhs'') -> do
            writeInstruction $ Assign (OutputProperty lhs'' propName) rhs''
            return $ Literal AST.LUnit

    AST.EAssign _ lhs rhs -> do
        lhs' <- generate env lhs
        rhs' <- generate env rhs
        for (both lhs' rhs') $ \(Reference lhs'', rhs'') -> do
            writeInstruction $ Assign lhs'' rhs''
            return $ Literal AST.LUnit

    AST.ELiteral _ lit -> do
        return $ Just $ Literal lit

    AST.EArrayLiteral _ elements -> do
        elements' <- runMaybeT $ mapM (MaybeT . generate env) elements
        return $ fmap ArrayLiteral elements'

    AST.ERecordLiteral _ props -> do
        props' <- runMaybeT $ mapM (MaybeT . generate env) props
        return $ fmap RecordLiteral props'

    AST.EIdentifier _ name -> do
        return $ Just $ Reference $ Binding name

    AST.EBinIntrinsic _ bi lhs rhs -> do
        lhs' <- generate env lhs
        rhs' <- generate env rhs
        for (both lhs' rhs') $ \(lhs'', rhs'') -> do
            newInstruction env $ \output -> BinIntrinsic output bi lhs'' rhs''

    AST.EIntrinsic _ iid -> do
        iid' <- runMaybeT $ traverse (MaybeT . generate env) iid
        for iid' $ \iid'' -> do
            newInstruction env $ \output -> Intrinsic output iid''

    AST.ESemi _ lhs rhs -> do
        _ <- generate env lhs
        generate env rhs

    AST.EMatch _ value cases -> do
        value' <- generate env value
        for value' $ \value'' -> do
            output <- lift $ newTempOutput env
            writeInstruction $ EmptyLet output
            cases' <- forM cases $ \(AST.Case pat expr') -> do
                expr'' <- subBlockWithOutput env output expr'
                return (pat, expr'')
            writeInstruction $ Match value'' cases'
            return $ Reference output

    AST.EIfThenElse _ cond ifTrue ifFalse -> do
        cond' <- generate env cond
        output <- lift $ newTempOutput env
        writeInstruction $ EmptyLet output
        ifTrue' <- subBlockWithOutput env output ifTrue
        ifFalse' <- subBlockWithOutput env output ifFalse
        for cond' $ \cond'' -> do
            writeInstruction $ If cond'' ifTrue' ifFalse'
            return $ Reference output

    AST.EWhile _ cond body -> do
        let boolType = AST.edata cond
        let unitType = AST.edata body
        body' <- subBlock env $
            AST.ESemi unitType
                (AST.EIfThenElse unitType
                    (AST.EIntrinsic boolType $ AST.INot $ cond)
                    (AST.EBreak unitType)
                    (AST.ELiteral unitType $ AST.LUnit))
                body
        writeInstruction $ Loop body'
        return $ Just $ Literal AST.LUnit

    AST.EReturn _ rv -> do
        rv' <- generate env rv
        forM_ rv' $ \rv'' -> do
            writeInstruction $ Return rv''
        return Nothing

    AST.EBreak _ -> do
        writeInstruction $ Break
        return Nothing

subBlock :: (MonadIO m, Show t) => Env -> AST.Expression AST.ResolvedReference t -> m [Instruction]
subBlock env expr = do
    (_output, instructions) <- liftIO $ runWriterT $ generate env expr
    return instructions

subBlockWithReturn :: (MonadIO m, Show t) => Env -> AST.Expression AST.ResolvedReference t -> m [Instruction]
subBlockWithReturn env expr = do
    (output, instrs) <- liftIO $ runWriterT $ generate env expr
    return $ case output of
        Just output' -> instrs ++ [Return output']
        Nothing -> instrs

subBlockWithOutput :: (MonadIO m, Show t) => Env -> Output -> AST.Expression AST.ResolvedReference t -> m [Instruction]
subBlockWithOutput env output expr = do
    (output', instrs) <- liftIO $ runWriterT $ generate env expr
    return $ case output' of
        Just output'' -> instrs ++ [Assign output output'']
        Nothing -> instrs

generateDecl :: Show t => Env -> AST.Declaration AST.ResolvedReference t -> DeclarationWriter ()
generateDecl env (AST.Declaration export decl) = do
    case decl of
        AST.DDeclare _ _ -> do
            -- declarations are not reflected into the IR
            return ()
        AST.DData name _ variants -> do
            writeDeclaration $ Declaration export $ DData name variants
        AST.DJSData name variants -> do
            writeDeclaration $ Declaration export $ DJSData name variants
        AST.DFun (AST.FunDef _ name params _retAnn body) -> do
            body' <- subBlockWithReturn env body
            writeDeclaration $ Declaration export $ DFun name (map fst params) body'
        AST.DLet _ _mut name _ defn -> do
            -- error if output has no return value
            defn' <- subBlockWithReturn env defn
            writeDeclaration $ Declaration export $ DLet name defn'
        AST.DType {} ->
            -- type aliases are not reflected into the IR
            return ()

generateModule :: Show t => AST.Module AST.ResolvedReference t -> IO Module
generateModule AST.Module{..} = do
    env <- newIORef 0
    decls <- fmap snd $ runWriterT $ do
        forM_ mDecls $ generateDecl env
    return decls

importsOf :: AST.Module a b -> [AST.ModuleName]
importsOf AST.Module{..} = map (\(AST.UnqualifiedImport mn) -> mn) mImports

generateProgram :: AST.Program -> IO Program
generateProgram AST.Program{..} = do
    let allModules = HashMap.toList pOtherModules

    let nodes = [(m, mn, importsOf m) | (mn, m) <- allModules]
    let (graph, getModule, _) = graphFromEdges nodes

    -- topologically sort
    let sortedModules = map getModule $ reverse $ topSort graph

    forM sortedModules $ \(mod', moduleName, _) ->
        fmap (moduleName,) $ generateModule mod'
