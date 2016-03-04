{-# LANGUAGE DeriveFunctor #-}

module Crux.Typecheck.Types
    ( ValueReference(..)
    , TypeReference(..)
    , PatternBinding(..)
    , Env(..)
    ) where

import Crux.TypeVar
    ( TypeVar(..)
    , TUserTypeDef(..)
    )
import Crux.Module.Types (LoadedModule)
import Crux.AST
    ( Mutability
    , ModuleName
    , ResolvedReference
    )
import           Crux.Prelude

-- TODO: newtype this somewhere and import it
type Name = Text

type HashTable k v = IORef (HashMap k v)

data ValueReference
    = ValueReference ResolvedReference Mutability TypeVar
    | ModuleReference ModuleName

data TypeReference = TypeReference TypeVar
    deriving (Eq)
instance Show TypeReference where
    show (TypeReference _tv) = "TypeBinding <typevar>"

-- same structure as TUserType constructor
data PatternBinding = PatternBinding
    (TUserTypeDef TypeVar) -- type of value being pattern matched
    [TypeVar] -- type parameters to type

data Env = Env
    { eThisModule :: ModuleName
    , eLoadedModules :: HashMap ModuleName LoadedModule
    , eNextTypeIndex :: IORef Int
    , eValueBindings :: HashTable Name ValueReference
    , eTypeBindings :: HashTable Name TypeReference
    , ePatternBindings :: HashTable Name PatternBinding
    , eReturnType :: Maybe TypeVar -- Nothing if top-level expression
    , eInLoop :: !Bool
    }
