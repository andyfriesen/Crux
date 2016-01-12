{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}

module IntegrationTest where

import Control.Monad (when)
import qualified Crux.AST             as AST
import qualified Crux.JSBackend      as JS
import qualified Crux.Error as Error
import qualified Crux.Gen             as Gen
import qualified Crux.Module
import           Crux.Tokens          (Pos (..))
import           Crux.Typecheck.Types (UnificationError (..), showTypeVarIO)
import qualified Data.HashMap.Strict  as HashMap
import           Data.Text            (Text)
import qualified Data.Text            as T
import qualified Data.Text.IO         as T
import           System.Exit          (ExitCode (..))
import           System.IO            (hFlush)
import           System.IO.Temp       (withSystemTempFile)
import           System.Process       (readProcessWithExitCode)
import           Test.Framework
import           Text.RawString.QQ    (r)
import qualified System.Directory.PathWalk as PathWalk
import qualified System.FilePath as FilePath
import System.Directory (doesDirectoryExist)

runProgram' :: AST.Program -> IO Text
runProgram' p = do
    m' <- Gen.generateProgram p
    let js = JS.generateJS m'
    withSystemTempFile "Crux.js" $ \path' handle -> do
        T.hPutStr handle js
        hFlush handle
        fmap T.pack $ do
            readProcessWithExitCode "node" [path'] "" >>= \case
                (ExitSuccess, stdout, _) -> return stdout
                (ExitFailure code, _, stderr) -> do
                    putStrLn $ "Process failed with code: " ++ show code ++ "\n" ++ stderr
                    putStrLn "Code:"
                    T.putStrLn js
                    fail $ "Process failed with code: " ++ show code ++ "\n" ++ stderr

run :: Text -> IO (Either Error.Error Text)
run src = do
    Crux.Module.loadProgramFromSource src >>= \case
        Left (_, e) -> return $ Left e
        Right m -> fmap Right $ runProgram' m

runMultiModule :: HashMap.HashMap AST.ModuleName Text -> IO (Either Error.Error Text)
runMultiModule sources = do
    Crux.Module.loadProgramFromSources sources >>= \case
        Left (_, e) -> return $ Left e
        Right m -> fmap Right $ runProgram' m

assertCompiles src = do
    result <- run $ T.unlines src
    case result of
        Right _ -> return ()
        Left err -> assertFailure $ "Compile failure: " ++ show err

assertOutput src outp = do
    result <- run $ T.unlines src
    case result of
        Right a -> assertEqual outp a
        Left err -> assertFailure $ "Compile failure: " ++ show err

assertUnificationError :: Pos -> String -> String -> Either Error.Error a -> IO ()
assertUnificationError pos a b (Left (Error.UnificationError (UnificationError actualPos _ at bt))) = do
    assertEqual pos actualPos

    as <- showTypeVarIO at
    bs <- showTypeVarIO bt
    assertEqual a as
    assertEqual b bs

assertUnificationError _ _ _ _ =
    assertFailure "Expected a unification error"

runIntegrationTest :: FilePath -> IO ()
runIntegrationTest root = do
    let mainPath = FilePath.combine root "main.cx"
    let stdoutPath = FilePath.combine root "stdout.txt"
    expected <- fmap T.pack $ readFile stdoutPath

    Crux.Module.loadProgramFromFile mainPath >>= \case
        Left err -> do
            fail $ show err
        Right program -> do
            putStrLn $ "testing program " ++ mainPath
            stdout <- runProgram' program
            assertEqual expected stdout

test_integration_tests = do
    let integrationRoot = "tests/integration"
    exists <- doesDirectoryExist integrationRoot
    when (not exists) $ do
        fail $ "Integration test directory " ++ integrationRoot ++ " does not exist!"
    PathWalk.pathWalk integrationRoot $ \d _dirnames filenames -> do
        when ("main.cx" `elem` filenames) $ do
            runIntegrationTest d

test_let_is_not_recursive_by_default = do
    result <- run $ T.unlines [ "let foo = fun (x) { foo(x) }" ]
    assertEqual result $ Left $ Error.UnificationError $ UnboundSymbol (Pos 1 1 21) "foo"

test_occurs_on_fun = do
    result <- run $ T.unlines
        [ "fun bad() { bad }"
        ]

    assertEqual (Left $ Error.UnificationError $ OccursCheckFailed (Pos 1 1 1)) result

test_occurs_on_sum = do
    result <- run $ T.unlines
        [ "data List a { Cons(a, List a), Nil }"
        , "fun bad(a) { Cons(a, a) }"
        ]

    assertEqual (Left $ Error.UnificationError $ OccursCheckFailed (Pos 1 2 14)) result

test_occurs_on_record = do
    result <- run $ T.unlines
        [ "fun bad(p) { { field: bad(p) } }"
        ]

    assertEqual (Left $ Error.UnificationError $ OccursCheckFailed (Pos 1 1 1)) result

test_incorrect_unsafe_js = do
    result <- run $ T.unlines
        [ "let bad = _unsafe_js"
        ]
    assertEqual (Left $ Error.UnificationError $ IntrinsicError (Pos 1 1 11) "Intrinsic _unsafe_js is not a value") result

test_annotation_is_checked = do
    result <- run $ T.unlines
        [ "let i: Number = \"hody\""
        ]

    assertUnificationError (Pos 1 1 1) "Number" "String" result

test_arrays_of_different_types_cannot_unify = do
    result <- run $ T.unlines
        [ "let _ = [[0], [\"\"]]"
        ]
    assertUnificationError (Pos 1 1 9) "Number" "String" result

test_record_annotation_is_checked2 = do
    result <- run $ T.unlines
        [ "let c: {} = _unsafe_js(\"console\")"
        , "fun main() {"
        , "    c.log(\"Hoop\")"
        , "}"
        , "let _ = main()"
        ]

    assertUnificationError (Pos 5 3 5) "{}" "{log: (TUnbound 15),..._16}" result
    -- assertEqual (Left "Unification error: Field 'log' not found in quantified record {} and {log: (TUnbound 6),f...}") result

test_comments = do
    result <- run $ T.unlines
        [ "// A list is either Nil, the empty case, or"
        , "// it is Cons an element and another list."
        , "data List a { Nil, Cons(a, List a), }"
        , ""
        , "/* TODO: Decide on an optimal name for this type alias"
        , " type Bogo = List */"
        , "type Bogo a = List a"
        , ""
        , "let hoop: Bogo Number = Cons(5, Nil)"
        ]
    assertEqual (Right "") result

test_comments2 = do
    result <- run $ T.unlines
        [ "/* this is a test */"
        , "let u = 8"
        ]
    assertEqual (Right "") result

test_nested_comments = do
    result <- run $ "/* /* foo */ */"
    assertEqual (Right "") result

test_let_mutable = do
    result <- run $ T.unlines
        [ "fun main() {"
        , "    let mutable x = 2"
        , "    x = x + 1"
        , "    print(x)"
        , "}"
        , "let _ = main()"
        ]

    assertEqual (Right "3\n") result

test_cannot_assign_to_immutable_binding = do
    result <- run $ T.unlines
        [ "fun main() {"
        , "    let x = 2"
        , "    x = x + 1"
        , "    print(x)"
        , "}"
        , "let _ = main()"
        ]

    -- assertEqual (Left "Not an lvar: EIdentifier (IPrimitive Number) (Local \"x\")") result
    assertEqual (Left $ Error.UnificationError $ NotAnLVar (Pos 5 3 5) "EIdentifier (IPrimitive Number) (Local \"x\")") result

test_assign_to_mutable_record_field = do
    result <- run $ T.unlines
        [ "fun main() {"
        , "    let a: {x: Number} = {x: 44}"
        , "    a.x = 22"
        , "    print(a)"
        , "}"
        , "let _ = main()"
        ]

    assertEqual (Right "{ x: 22 }\n") result

test_cannot_assign_to_immutable_record_field = do
    result <- run $ T.unlines
        [ "fun main() {"
        , "    let a: {const x: Number} = {x: 44}"
        , "    a.x = 22"
        , "    print(a)"
        , "}"
        , "let _ = main()"
        ]

    assertEqual
        -- (Left "Not an lvar: ELookup (IPrimitive Number) (EIdentifier (IRecord (RecordType RecordClose [TypeRow {trName = \"x\", trMut = RImmutable, trTyVar = IPrimitive Number}])) (Local \"a\")) \"x\"")
        (Left $ Error.UnificationError $ NotAnLVar (Pos 5 3 5) "ELookup (IPrimitive Number) (EIdentifier (IRecord (RecordType RecordClose [TypeRow {trName = \"x\", trMut = RImmutable, trTyVar = IPrimitive Number}])) (Local \"a\")) \"x\"")
        result

test_mutable_record_field_requirement_is_inferred = do
    result <- run $ T.unlines
        [ "fun swap(p) {"
        , "    let t = p.x"
        , "    p.x = p.y"
        , "    p.y = t"
        , "}"
        , "fun main() {"
        , "    let a: {const x: Number, const y: Number} = {x:44, y:0}"
        , "    swap(a)"
        , "}"
        , "let _ = main()"
        ]

    assertEqual
        (Left $ Error.UnificationError $ RecordMutabilityUnificationError (Pos 5 8 5) "x" "Record field mutability does not match")
        result

test_inferred_record_field_accepts_either_mutable_or_immutable_fields = do
    result <- run $ T.unlines
        [ "fun manhattan(p) {"
        , "    p.x + p.y"
        , "}"
        , ""
        , "fun main() {"
        , "    let a: {const x: Number, const y: Number} = {x:44, y:0}"
        , "    print(manhattan(a))"
        , ""
        , "    let b: {mutable x: Number, mutable y: Number} = {x:0, y:0}"
        , "    print(manhattan(b))"
        , "}"
        , "let _ = main()"
        ]

    assertEqual (Right "44\n0\n") result

test_jsffi_data_type_names_and_values_can_be_used = do
    result <- run $ T.unlines
        [ "data jsffi Method {"
        , "    Get=\"GET\","
        , "    Post=\"POST\","
        , "}"
        , "let result: Method = Get"
        , "let _ = print(result)"
        ]

    assertEqual (Right "GET\n") result

test_record_self_unification = do
    result <- run $ T.unlines
        [ "let r = {}"
        , "fun main(o) {"
        , "    if False then o else r"
        , "}"
        , "let _ = main(r)"
        ]

    assertEqual (Right "") result

test_return_unifies_with_anything = do
    result <- run $ T.unlines
        [ "fun a() {"
        , "    let p ="
        , "        if True"
        , "            then return \"hody\""
        , "            else 22"
        , "    toString(p)"
        , "}"
        ]

    assertEqual (Right "") result

test_while_loops = do
    result <- run $ T.unlines
        [ "fun fib(n) {"
        , "    let mutable count = n"
        , "    let mutable a = 0"
        , "    let mutable b = 1"
        , ""
        , "    while count > 0 {"
        , "        let t = a"
        , "        a = b"
        , "        b = b + t"
        , "        count = count - 1"
        , "    }"
        , "    a"
        , "}"
        , ""
        , "fun main() {"
        , "    let mutable i = 1"
        , "    while i < 10 {"
        , "        print(fib(i))"
        , "        i = i + 1"
        , "    }"
        , "}"
        , ""
        , "let _ = main()"
        ]

    assertEqual (Right "1\n1\n2\n3\n5\n8\n13\n21\n34\n") result

test_quantify_user_types_correctly =
    assertCompiles
        [ "data Option a {"
        , "    None,"
        , "    Some(a)"
        , "}"
        , ""
        , "let isNull = _unsafe_js(\"function(o) { return null === o; }\")"
        , ""
        , "fun toMaybeString(o) {"
        , "    if isNull(o)"
        , "        then None"
        , "        else Some(_unsafe_coerce(o))"
        , "}"
        ]

test_interior_unbound_types_are_ok =
    assertCompiles
        [ "let _unsafe_new = _unsafe_js(\"function (len) { return new Array(len); }\")"
        , "export fun replicate(element, len) {"
        , "    let arr = _unsafe_new(len)"
        , "}"
        ]

test_type_annotation_for_parametric_type =
    assertCompiles
        [ "data Option a { None, Some(a) }"
        , "let x: Option Number = Some(22)"
        ]

test_polymorphic_type_annotations_are_universally_quantified =
    assertCompiles
        [ "data Option a { None, Some(a) }"
        , ""
        , "let none: () -> Option a = fun () { None }"
        , ""
        , "fun f() {"
        , "    let n: Option Number = none()"
        , "}"
        ]

test_polymorphic_type_annotations_are_universally_quantified2 = do
    rv <- run $ T.unlines
        [ "let f: (Number) -> Number = fun (i) { i }"
        , "let g: (a) -> a = fun (i) { i }"
        , "let _ = f(g(\"hello\"))"
        ]
    assertUnificationError (Pos 1 3 9) "Number" "String" rv

test_polymorphic_type_annotations_are_universally_quantified3 =
    assertCompiles
        [ "let f: (Number) -> Number = fun (i) { i }"
        , "let g: (a) -> b = fun (i) { _unsafe_coerce(i) }"
        , "let _ = f(g(\"hello\"))"
        ]

test_polymorphic_type_annotations_are_universally_quantified4 = do
    rv <- run $ T.unlines
        [ "let f: (a) -> Number = fun (i) { i }"
        ]
    assertUnificationError (Pos 1 1 1) "Number" "TQuant 7" rv

test_type_annotations_on_function_decls =
    assertCompiles
        [ "fun id_int(x: int): int { x }"
        ]

test_type_annotations_on_function_decls2 = do
    rv <- run $ T.unlines
        [ "fun id_int(x: a): Number { x }"
        ]
    assertUnificationError (Pos 1 1 1) "Number" "TQuant 10" rv

test_arrays =
    assertOutput
        [ "fun main() {"
        , "    let arr = replicate(\"toot\", 4)"
        , "    each(arr, fun(e) {"
        , "        print(e)"
        , "    })"
        , "}"
        , "let _ = main()"
        ]
        "toot\ntoot\ntoot\ntoot\n"

test_concatenate_strings = do
    assertOutput ["let _ = print(\"foo\" + \"bar\")"] "foobar\n"

test_quantified_record = do
    assertCompiles
        [ "fun errorResponse(response, statusCode: Number) {"
        , "    response.statusCode = statusCode"
        , "}"
        , "fun handleRequest(response) {"
        , "    errorResponse(response, 405)"
        , "    errorResponse(response, 404)"
        , "}"
        ]

test_for_loop = do
    result <- run $ T.unlines
        [ "fun main() {"
        , "  for x in [1, 2, 3] {"
        , "    print(x)"
        , "  }"
        , "}"
        , "let _ = main()"
        ]

    assertEqual (Right "1\n2\n3\n") result

test_export_and_import = do
    main <- return $ T.unlines
        [ "import { Halloumi(...) }"
        , "fun main() {"
        , "  print(\"outside\")"
        , "  fn()"
        , "}"
        , "let _ = main()"
        ]

    halloumi <- return $ T.unlines
        [ "export fun fn() {"
        , "  print(\"inside\")"
        , "}"
        ]

    result <- runMultiModule $ HashMap.fromList
        [ ("Main", main)
        , ("Halloumi", halloumi)
        ]
    assertEqual (Right "outside\ninside\n") result

test_string_methods = do
    result <- run $ T.unlines
        [ "let _ = print(\"foo\"->endsWith(\"oo\"))"
        , "let _ = print(\"bar\"->endsWith(\"oo\"))"
        ]
    assertEqual (Right "true\nfalse\n") result

test_tdnr_quantifies_function = do
    result <- run $ T.unlines
        [ "let a = [1, 2, 3]"
        , "let _ = a->each(fun(i) {"
        , "    print(i)"
        , "})"
        ]
    assertEqual (Right "1\n2\n3\n") result

test_tdnr_inside_each = do
    result <- run $ T.unlines
        [ "let _ = [1, 2, 3]->each(fun(i) {"
        , "    i->print()"
        , "})"
        ]
    assertEqual (Right "1\n2\n3\n") result

test_tdnr_inside_for_loop = do
    result <- run $ T.unlines
        [ "let _ = for i in [1, 2, 3] {"
        , "    i->print()"
        , "}"
        ]
    assertEqual (Right "1\n2\n3\n") result

test_tdnr_with_arg_annotation = do
    assertCompiles
        [ "fun f(s: String) {"
        , "  s->endsWith(\"es\")"
        , "}"
        ]

test_boolean_expressions = do
    assertOutput
        [ "let b = 0 <= 5 && 5 < 10"
        , "let _ = print(b)"
        ]
        "true\n"

test_name_functions_javascript_keywords = do
    assertOutput
        [ "export fun catch() {"
        , "  let enum = ()"
        , "}"
        , "let _ = catch()"
        , "export let finally = catch"
        , "let _ = finally()"
        ]
        ""

test_prelude_provides_None = do
    assertCompiles
        [ "let a = None"
        ]

test_prelude_provides_Some = do
    assertCompiles
        [ "let a = Some(8)"
        ]

test_escaped_strings = do
    result1 <- run $ T.unlines
        [ [r|let _ = print("\0\a\b\f\n\r\t\v\\\'\"\?")|]
        ]
    assertEqual (Right "\NUL\a\b\f\n\r\t\v\\'\"?\n") result1

    result2 <- run $ T.unlines
        [ [r|let _ = print("\x00\x01\x02")|]
        ]
    assertEqual (Right "\0\1\2\n") result2

    -- TODO: tests for \u and \U

test_cannot_omit_arguments = do
    result <- run $ T.unlines
        [ "fun f(x) {}"
        , "let _ = f()"
        ]
    assertUnificationError (Pos 1 2 9) "((TUnbound 14)) -> Unit" "() -> Unit" result

test_exported_sum_cannot_depend_on_non_exported_type = do
    result <- runMultiModule $ HashMap.fromList
        [ ( "A", T.unlines
            [ "data A {}"
            , "export data B { B(A) }"
            ]
          )
        , ("Main", T.unlines
            [ "import { A(...) }"
            ]
          )
        ]
    err <- assertLeft result
    case err of
        Error.UnificationError (ExportError _pos message) ->
            assertEqual "Variant \"B\" of exported data type \"B\" depends on nonexported data type \"A\" (defined at 1,1)" message
        _ ->
            assertFailure $ "Expected ExportError but got " ++ show err

test_can_import_types_with_cyclic_dependencies = do
    result <- runMultiModule $ HashMap.fromList
        [ ("A", T.unlines
            [ "export data A { A(B), NA }"
            , "export data B { B(A), NB }"
            ]
          )
        , ("Main", T.unlines
            [ "import { A(...) }"
            , "let a = A(B(NA))"
            ]
          )
        ]
    assertEqual (Right "") result
