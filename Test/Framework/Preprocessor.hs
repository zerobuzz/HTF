{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

--
-- Copyright (c) 2009-2014 Stefan Wehr - http://www.stefanwehr.de
--
-- This library is free software; you can redistribute it and/or
-- modify it under the terms of the GNU Lesser General Public
-- License as published by the Free Software Foundation; either
-- version 2.1 of the License, or (at your option) any later version.
--
-- This library is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- Lesser General Public License for more details.
--
-- You should have received a copy of the GNU Lesser General Public
-- License along with this library; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA
--

module Test.Framework.Preprocessor ( transform, progName ) where

import Control.Monad
import qualified Data.Text as T
import Data.Char ( toLower, isSpace, isDigit )
import Data.Maybe ( mapMaybe )
import qualified Data.List as List
import System.IO ( hPutStrLn, stderr )
import Language.Preprocessor.Cpphs ( runCpphs,
                                     CpphsOptions(..),
                                     BoolOptions(..),
                                     defaultCpphsOptions)

import Test.Framework.HaskellParser
import Test.Framework.Location

_DEBUG_ :: Bool
_DEBUG_ = False

progName :: String
progName = "htfpp"

htfModule :: String
htfModule = "Test.Framework"

mkName varName fullModuleName =
    "htf_" ++
    map (\c -> if c == '.' then '_' else c)
        (fullModuleName ++ "." ++
         (case varName of
            'h':'t':'f':'_':s -> s
            s -> s))

thisModulesTestsFullName :: String -> String
thisModulesTestsFullName = mkName thisModulesTestsName

importedTestListFullName :: String -> String
importedTestListFullName = mkName importedTestListName

thisModulesTestsName :: String
thisModulesTestsName = "htf_thisModulesTests"

importedTestListName :: String
importedTestListName = "htf_importedTests"

nameDefines :: ModuleInfo -> [(String, String)]
nameDefines info =
    [(thisModulesTestsName, thisModulesTestsFullName (mi_moduleName info)),
     (importedTestListName, importedTestListFullName (mi_moduleName info))]

allAsserts :: [String]
allAsserts =
    withGs ["assertBool"
           ,"assertEqual"
           ,"assertEqualPretty"
           ,"assertEqualNoShow"
           ,"assertNotEqual"
           ,"assertNotEqualPretty"
           ,"assertNotEqualNoShow"
           ,"assertListsEqualAsSets"
           ,"assertElem"
           ,"assertEmpty"
           ,"assertNotEmpty"
           ,"assertLeft"
           ,"assertLeftNoShow"
           ,"assertRight"
           ,"assertRightNoShow"
           ,"assertJust"
           ,"assertNothing"
           ,"assertNothingNoShow"
           ,"subAssert"
           ,"subAssertVerbose"
           ] ++ ["assertThrows"
                ,"assertThrowsSome"
                ,"assertThrowsIO"
                ,"assertThrowsSomeIO"
                ,"assertThrowsM"
                ,"assertThrowsSomeM"]
    where
      withGs l =
          concatMap (\s -> [s, 'g':s]) l

assertDefines :: Bool -> String -> [(String, String)]
assertDefines hunitBackwardsCompat prefix =
    concatMap fun allAsserts ++ [("assertFailure", expansion "assertFailure" "_")]
    where
      fun a =
          if hunitBackwardsCompat
             then [(a, expansion a "Verbose_"), (a ++ "HTF", expansion a "_")]
             else [(a, expansion a "_"), (a ++ "Verbose", expansion a "Verbose_")]
      expansion a suffix = "(" ++ prefix ++ a ++ suffix ++ " (" ++
                           prefix ++ "makeLoc __FILE__ __LINE__))"

warn :: String -> IO ()
warn s =
    hPutStrLn stderr $ progName ++ " warning: " ++ s

note :: String -> IO ()
note s =
    when _DEBUG_ $ hPutStrLn stderr $ progName ++ " note: " ++ s

data ModuleInfo = ModuleInfo { mi_htfPrefix  :: String
                             , mi_htfImports :: [ImportDecl]
                             , mi_defs       :: [Definition]
                             , mi_moduleName :: String }
                  deriving (Show)

data Definition = TestDef String Location String
                | PropDef String Location String
                  deriving (Eq, Show)

data ImportOrPragma = IsImport ImportDecl | IsPragma Pragma
                  deriving (Show)

analyse :: FilePath -> String
        -> IO (ParseResult ModuleInfo)
analyse originalFileName inputString =
    do parseResult <- parse originalFileName inputString
       case parseResult of
         ParseOK (Module moduleName imports decls pragmas) ->
             do -- putStrLn $ show decls
                let defs = mapMaybe defFromDecl decls
                    htfImports = findHtfImports imports pragmas
                htfPrefix <-
                  case mapMaybe prefixFromImport imports of
                    (s:_) -> return s
                    [] -> do warn ("No import found for " ++ htfModule ++
                                   " in " ++ originalFileName)
                             return (htfModule ++ ".")
                return $ ParseOK (ModuleInfo htfPrefix htfImports defs moduleName)
         ParseError loc err -> return (ParseError loc err)
    where
      prefixFromImport :: ImportDecl -> Maybe String
      prefixFromImport (ImportDecl s qualified alias _)
          | s == htfModule =
              if qualified
                  then case alias of
                         Just s' -> Just $ s' ++ "."
                         Nothing -> Just $ s ++ "."
                  else Just ""
      prefixFromImport _ = Nothing
      defFromDecl :: Decl -> Maybe Definition
      defFromDecl (Decl loc name) = defFromNameAndLoc name loc
      defFromNameAndLoc :: Name -> Location -> Maybe Definition
      defFromNameAndLoc name loc =
          case name of
            ('t':'e':'s':'t':'_':rest) | not (null rest) ->
                Just (TestDef rest loc name)
            ('p':'r':'o':'p':'_':rest) | not (null rest) ->
                Just (PropDef rest loc name)
            _ -> Nothing
      findHtfImports allImports allPragmas =
          let importPragmas = filter (\p -> pr_name p == "HTF_TESTS") allPragmas
              importsAndPragmas = List.sortBy cmpByLine (map IsImport allImports ++
                                                         map IsPragma importPragmas)
              loop (IsImport imp : IsPragma prag : rest) =
                  if lineNumber (imp_loc imp) == lineNumber (pr_loc prag)
                     then imp : loop rest
                     else loop rest
              loop (_ : rest) = loop rest
              loop [] = []
          in loop importsAndPragmas
      cmpByLine x y = getLine x `compare` getLine y
      getLine (IsImport imp) = (lineNumber (imp_loc imp))
      getLine (IsPragma prag) = (lineNumber (pr_loc prag))

breakOn :: T.Text -> T.Text -> Maybe (T.Text, T.Text)
breakOn t1 t2 =
    let (pref, suf) = T.breakOn t1 t2
    in if pref == t2
       then Nothing
       else Just (pref, T.drop (T.length t1) suf)

poorMensAnalyse :: FilePath -> String -> IO ModuleInfo
poorMensAnalyse originalFileName inputString =
    let (modName, defs, impDecls) = doAna (zip [1..] (lines inputString)) ("", [], [])
    in return $ ModuleInfo "Test.Framework." impDecls defs modName
    where
      defEqByName (TestDef n1 _ _) (TestDef n2 _ _) = n1 == n2
      defEqByName (PropDef n1 _ _) (PropDef n2 _ _) = n1 == n2
      defEqByName _ _ = False
      doAna [] (modName, revDefs, impDecls) = (modName, reverse (List.nubBy defEqByName revDefs), reverse impDecls)
      doAna ((lineNo, line) : restLines) (modName, defs, impDecls) =
          case line of
            'm':'o':'d':'u':'l':'e':rest ->
                if null modName
                then doAna restLines (takeWhile (not . isSpace) (dropWhile isSpace rest),
                                      defs, impDecls)
                else doAna restLines (modName, defs, impDecls)
            't':'e':'s':'t':'_':rest ->
                let testName = takeWhile (not . isSpace) rest
                    def = TestDef testName loc ("test_" ++ testName)
                in doAna restLines (modName, def : defs, impDecls)
            'p':'r':'o':'p':'_':rest ->
                let testName = takeWhile (not . isSpace) rest
                    def = PropDef testName loc ("prop_" ++ testName)
                in doAna restLines (modName, def : defs, impDecls)
            'i':'m':'p':'o':'r':'t':rest ->
                case breakOn importPragma (T.pack rest) of
                  Just (pref, suf) ->
                      case poorMensParseImportLine loc (pref `T.append` suf) of
                        Just impDecl -> doAna restLines (modName, defs, impDecl : impDecls)
                        Nothing -> doAna restLines (modName, defs, impDecls)
                  Nothing -> doAna restLines (modName, defs, impDecls)
            _ -> doAna restLines (modName, defs, impDecls)
          where
            loc = makeLoc originalFileName lineNo
            importPragma = T.pack "{-@ HTF_TESTS @-}"

poorMensParseImportLine :: Location -> T.Text -> Maybe ImportDecl
poorMensParseImportLine loc t =
    let (q, rest) =
            case breakOn "qualified" t of
              Nothing -> (False, T.strip t)
              Just (_, rest) -> (True, T.strip rest)
        modName = T.takeWhile (not . isSpace) rest
        afterModName = T.strip $ T.drop (T.length modName) rest
    in case breakOn "as" afterModName of
         Nothing -> Just $ ImportDecl (T.unpack modName) q Nothing loc
         Just (_, suf) ->
             let strippedSuf = T.strip suf
                 alias = if T.null strippedSuf then Nothing else Just (T.unpack strippedSuf)
             in Just $ ImportDecl (T.unpack modName) q alias loc

transform :: Bool -> FilePath -> String -> IO String
transform hunitBackwardsCompat originalFileName input =
    do analyseResult <- analyse originalFileName input
       case analyseResult of
         ParseError loc err ->
             do poorInfo <- poorMensAnalyse originalFileName input
                note ("Parsing of " ++ originalFileName ++ " failed at line "
                      ++ show (lineNumber loc) ++ ": " ++ err ++
                      "\nFalling back to poor man's parser. This parser may " ++
                      "return incomplete results. The result returned was: " ++
                      "\nPrefix: " ++ mi_htfPrefix poorInfo ++
                      "\nModule name: " ++ mi_moduleName poorInfo ++
                      "\nDefinitions: " ++ show (mi_defs poorInfo) ++
                      "\nHTF imports: " ++ show (mi_htfImports poorInfo))
                preprocess poorInfo input
         ParseOK info ->
             preprocess info input
    where
      preprocess :: ModuleInfo -> String -> IO String
      preprocess info input =
          do preProcessedInput <- runCpphs (cpphsOptions info) originalFileName
                                           fixedInput
             return $ preProcessedInput ++ "\n\n" ++ additionalCode info ++ "\n"
          where
              -- fixedInput serves two purposes:
              -- 1. add a trailing \n
              -- 2. turn lines of the form '# <number> "<filename>"' into line directives '#line <number> <filename>'
              -- (see http://gcc.gnu.org/onlinedocs/cpp/Preprocessor-Output.html#Preprocessor-Output).
              fixedInput :: String
              fixedInput = (unlines . map fixLine . lines) input
                  where
                    fixLine s =
                        case parseCppLineInfoOut s of
                          Just (line, fileName) -> "#line " ++ line ++ " " ++ fileName
                          _ -> s
      cpphsOptions :: ModuleInfo -> CpphsOptions
      cpphsOptions info =
          defaultCpphsOptions { defines =
                                    defines defaultCpphsOptions ++
                                    assertDefines hunitBackwardsCompat (mi_htfPrefix info) ++
                                    nameDefines info
                              , boolopts = (boolopts defaultCpphsOptions) { lang = True } -- lex as haskell
                              }
      additionalCode :: ModuleInfo -> String
      additionalCode info =
          thisModulesTestsFullName (mi_moduleName info) ++ " :: " ++
            mi_htfPrefix info ++ "TestSuite\n" ++
          thisModulesTestsFullName (mi_moduleName info) ++ " = " ++
            mi_htfPrefix info ++ "makeTestSuite" ++
          " " ++ show (mi_moduleName info) ++
          " [\n" ++ List.intercalate ",\n"
                          (map (codeForDef (mi_htfPrefix info)) (mi_defs info))
          ++ "\n  ]\n" ++ importedTestListCode info
      codeForDef :: String -> Definition -> String
      codeForDef pref (TestDef s loc name) =
          locPragma loc ++ pref ++ "makeUnitTest " ++ (show s) ++ " " ++ codeForLoc pref loc ++
          " " ++ name
      codeForDef pref (PropDef s loc name) =
          locPragma loc ++ pref ++ "makeQuickCheckTest " ++ (show s) ++ " " ++
          codeForLoc pref loc ++ " (" ++ pref ++ "qcAssertion " ++ name ++ ")"
      locPragma :: Location -> String
      locPragma loc =
          "{-# LINE " ++ show (lineNumber loc) ++ " " ++ show (fileName loc) ++ " #-}\n    "
      codeForLoc :: String -> Location -> String
      codeForLoc pref loc = "(" ++ pref ++ "makeLoc " ++ show (fileName loc) ++
                            " " ++ show (lineNumber loc) ++ ")"
      importedTestListCode :: ModuleInfo -> String
      importedTestListCode info =
          let l = mi_htfImports info
          in case l of
               [] -> ""
               _ -> (importedTestListFullName (mi_moduleName info)
                     ++ " :: [" ++ mi_htfPrefix info ++ "TestSuite]\n" ++
                     importedTestListFullName (mi_moduleName info)
                     ++ " = [\n    " ++
                     List.intercalate ",\n     " (map htfTestsInModule l) ++
                     "\n  ]\n")
      htfTestsInModule :: ImportDecl -> String
      htfTestsInModule imp = qualify imp (thisModulesTestsFullName (imp_moduleName imp))
      qualify :: ImportDecl -> String -> String
      qualify imp name =
          case (imp_qualified imp, imp_alias imp) of
            (False, _) -> name
            (True, Just alias) -> alias ++ "." ++ name
            (True, _) -> imp_moduleName imp ++ "." ++ name
