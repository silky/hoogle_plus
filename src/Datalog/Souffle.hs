module Datalog.Souffle 
    ( runSouffle
    , writeSouffle
    ) where

import Datalog.Datalog
import Datalog.SouffleType
import Database.Environment
import Text.Read
import Types.Experiments
import Types.Environment
import Types.Type
import Types.IOFormat
import Types.Program
import HooglePlus.Utils
import Synquid.Type

import Control.Monad.Logic
import Control.Lens
import qualified Data.Map as Map
import System.Process
import System.IO
import System.Directory
import Text.Printf

soufflePreamble = unlines [ ".type ListSym = [head: symbol, tail: ListSym]"
                          , ".type Program = [fun: symbol, args: ListProgram]"
                          , ".type ListProgram = [head: Program, tail: ListProgram]"
                          , ".type ListTyp = [head: Type, tail: ListTyp]"
                          , ".type Type = [a: symbol, b: ListTyp]"
                          , ".input funName"
                          , ".decl funName(f: symbol)"
                          , ".input inh"
                          , ".decl inh(t: Type, x: symbol)"
                          , ".decl sat(t: Type, fs: Program, d: number)"
                          , "sat(t, [x, nil], 0) :- inh(t, x)."
                          , ".decl query(fs: Program)"
                          , ".output query"
                          ]

runSouffle :: SearchParams -> Environment -> RSchema -> [Example] -> Int -> LogicT IO ()
runSouffle params env goal examples d = do
    paths <- liftIO $ findPath env goal d
    ifte (msum $ map (enumeratePath params env goal examples) paths)
         return
         (runSouffle params env goal examples (d + 1))

findPath :: Environment -> RSchema -> Int -> IO [UProgram]
findPath env goal d = do
    -- get higher-order arguments
    let args = over _2 (shape . toMonotype) (Map.toList (env ^. arguments))
    let hoArgs = filter (isFunctionType . snd) args
    let hoArgSat = map (uncurry writeFunction) hoArgs
    -- write query into the file
    let dstTyp = lastType (shape (toMonotype goal))
    let query = printf "query(P) :- sat(%s, P, D), D <= %d, D >= 0." (writeType (typeVarsOf dstTyp) (SouffleType dstTyp)) d
    -- write depth into the constraints
    let src = "./data/souffle/input.dl"
    let dst = "./data/souffle/main.dl"
    fileContent <- readFile src
    writeFile dst (replaceId "{}" (show (d - 1)) fileContent ++ unlines (query:hoArgSat))
    -- write the arguments into the file
    let packedArgs = over _2 SouffleType args
    writeFile "./data/souffle/inh.facts" (unlines $ map (uncurry writeArg) args)
    -- execute the solver
    readProcess "souffle" ["--fact-dir=./data/souffle/", "--output-dir=./data/souffle/", "./data/souffle/main.dl"] ""
    -- read results
    out <- readFile "./data/souffle/query.csv"
    return $ map read $ lines out :: IO [UProgram]

writeSouffle :: Environment -> IO ()
writeSouffle env = do
    -- write datalog templates
    writeFile "./data/souffle/input.dl" $
        unlines (soufflePreamble : map (uncurry writeFunctionSouffle) 
                (Map.toList $ env ^. groups))
    -- write datalog function names
    writeFile "./data/souffle/funName.facts" $
        unlines (Map.keys (env ^. groups))