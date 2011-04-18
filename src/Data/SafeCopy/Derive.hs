{-# LANGUAGE TemplateHaskell #-}
module Data.SafeCopy.Derive (deriveSafeCopy, deriveSafeCopySimple) where

import Data.Binary (getWord8, putWord8)
import Data.SafeCopy.SafeCopy

import Language.Haskell.TH hiding (Kind(..))
import Control.Applicative
import Control.Monad
import Data.Word (Word8) -- Haddock

-- | Derive an instance of 'SafeCopy'.
--
--   When serializing, we put a 'Word8' describing the
--   constructor (if the data type has more than one
--   constructor).  For each type used in the constructor, we
--   call 'getSafePut' (which immediately serializes the version
--   of the type).  Then, for each field in the constructor, we
--   use one of the put functions obtained in the last step.
--
--   For example, given the data type and the declaration below
--
--   @
--data T0 b = T0 b Int
--deriveSafeCopy 1 'base ''T0
--   @
--
--   we generate
--
--   @
--instance (SafeCopy a, SafeCopy b) =>
--         SafeCopy (T a b) where
--    putCopy (T0 arg1 arg2) = contain $ do put_b   <- getSafePut
--                                          put_Int <- getSafePut
--                                          put_b   arg1
--                                          put_Int arg2
--                                          return ()
--    getCopy = contain $ do get_b   <- getSafeGet
--                           get_Int <- getSafeGet
--                           return T0 \<*\> get_b \<*\> get_Int
--    version = 1
--    kind = base
--   @
--
--   And, should we create another data type as a newer version of @T0@, such as
--
--   @
--data T a b = C a a | D b Int
--
--deriveSafeCopy 1 'extension ''T
--
--instance SafeCopy b => Migrate (T a b) where
--  type MigrateFrom (T a b) = T0 b
--  migrate (T0 b i) = D b i
--   @
--
--   we generate
--
--   @
--instance (SafeCopy a, SafeCopy b) =>
--         SafeCopy (T a b) where
--    putCopy (C arg1 arg2) = contain $ do putWord8 0
--                                         put_a <- getSafePut
--                                         put_a arg1
--                                         put_a arg2
--                                         return ()
--    putCopy (D arg1 arg2) = contain $ do putWord8 1
--                                         put_b   <- getSafePut
--                                         put_Int <- getSafePut
--                                         put_b   arg1
--                                         put_Int arg2
--                                         return ()
--    getCopy = contain $ do tag <- getWord8
--                           case tag of
--                             0 -> do get_a <- getSafeGet
--                                     return C \<*\> get_a \<*\> get_a
--                             1 -> do get_b   <- getSafeGet
--                                     get_Int <- getSafeGet
--                                     return D \<*\> get_b \<*\> get_Int
--                             _ -> fail $ \"Could not identify tag \\\"\" ++
--                                         show tag ++ \"\\\" for type Main.T \" ++
--                                         \"that has only 2 constructors.  \" ++
--                                         \"Maybe your data is corrupted?\"
--    version = 1
--    kind = extension
--   @
--
--   Note that by using getSafePut, we saved 4 bytes in the case
--   of the @C@ constructor.  For @D@ and @T0@, we didn't save
--   anything.  The instance derived by this function always use
--   at most the same space as those generated by
--   'deriveSafeCopySimple', but never more (as we don't call
--   'getSafePut'/'getSafeGet' for types that aren't needed).
--
--   Note that you may use 'deriveSafeCopySimple' with one
--   version of your data type and 'deriveSafeCopy' in another
--   version without any problems.
deriveSafeCopy :: Integer -> Name -> Name -> Q [Dec]
deriveSafeCopy = internalDeriveSafeCopy Normal

-- | Derive an instance of 'SafeCopy'.  The instance derived by
--   this function is simpler than the one derived by
--   'deriveSafeCopy' in that we always use 'safePut' and
--   'safeGet' (instead of 'getSafePut' and 'getSafeGet').
--
--   When serializing, we put a 'Word8' describing the
--   constructor (if the data type has more than one constructor)
--   and, for each field of the constructor, we use 'safePut'.
--
--   For example, given the data type and the declaration below
--
--   @
--data T a b = C a a | D b Int
--
--deriveSafeCopySimple 1 'base ''T
--   @
--
--   we generate
--
--   @
--instance (SafeCopy a, SafeCopy b) =>
--         SafeCopy (T a b) where
--    putCopy (C arg1 arg2) = contain $ do putWord8 0
--                                         safePut arg1
--                                         safePut arg2
--                                         return ()
--    putCopy (D arg1 arg2) = contain $ do putWord8 1
--                                         safePut arg1
--                                         safePut arg2
--                                         return ()
--    getCopy = contain $ do tag <- getWord8
--                           case tag of
--                             0 -> do return C \<*\> safeGet \<*\> safeGet
--                             1 -> do return D \<*\> safeGet \<*\> safeGet
--                             _ -> fail $ \"Could not identify tag \\\"\" ++
--                                         show tag ++ \"\\\" for type Main.T \" ++
--                                         \"that has only 2 constructors.  \" ++
--                                         \"Maybe your data is corrupted?\"
--    version = 1
--    kind = base
--   @
--
--   Using this simpler instance means that you may spend more
--   bytes when serializing data.  On the other hand, it is more
--   straightforward and may match any other format you used in
--   the past.
--
--   Note that you may use 'deriveSafeCopy' with one version of
--   your data type and 'deriveSafeCopySimple' in another version
--   without any problems.
deriveSafeCopySimple :: Integer -> Name -> Name -> Q [Dec]
deriveSafeCopySimple = internalDeriveSafeCopy Simple

data DeriveType = Normal | Simple

internalDeriveSafeCopy :: DeriveType -> Integer -> Name -> Name -> Q [Dec]
internalDeriveSafeCopy deriveType versionId kindName tyName
    = do info <- reify tyName
         case info of
           TyConI (DataD cxt _name tyvars cons _derivs)
             | length cons > 255 -> fail $ "Can't derive SafeCopy instance for: " ++ show tyName ++
                                           ". The datatype must have less than 256 constructors."
             | otherwise         -> worker cxt tyvars (zip [0..] cons)
           TyConI (NewtypeD cxt _name tyvars con _derivs)
             -> worker cxt tyvars [(0, con)]
           _ -> fail $ "Can't derive SafeCopy instance for: " ++ show (tyName, info)
    where worker context tyvars cons
              = let ty = foldl appT (conT tyName) [ varT var | PlainTV var <- tyvars ]
                in (:[]) <$> instanceD (cxt $ [classP ''SafeCopy [varT var] | PlainTV var <- tyvars] ++ map return context)
                                       (conT ''SafeCopy `appT` ty)
                                       [ mkPutCopy deriveType cons
                                       , mkGetCopy deriveType tyName cons
                                       , valD (varP 'version) (normalB (litE (integerL versionId))) []
                                       , valD (varP 'kind) (normalB (varE kindName)) []
                                       ]

mkPutCopy :: DeriveType -> [(Integer, Con)] -> DecQ
mkPutCopy deriveType cons = funD 'putCopy $ map mkPutClause cons
    where
      manyConstructors = length cons > 1
      mkPutClause (conNumber, con)
          = do putVars <- replicateM (conSize con) (newName "arg")
               (putFunsDecs, putFuns) <- case deriveType of
                                           Normal -> mkSafeFunctions "safePut_" 'getSafePut con
                                           Simple -> return ([], const 'safePut)
               let putClause   = conP (conName con) (map varP putVars)
                   putCopyBody = varE 'contain `appE` doE (
                                   [ noBindS $ varE 'putWord8 `appE` (litE $ IntegerL conNumber) | manyConstructors ] ++
                                   putFunsDecs ++
                                   [ noBindS $ varE (putFuns typ) `appE` varE var | (typ, var) <- zip (conTypes con) putVars ] ++
                                   [ noBindS $ varE 'return `appE` tupE [] ])
               clause [putClause] (normalB putCopyBody) []

mkGetCopy :: DeriveType -> Name -> [(Integer, Con)] -> DecQ
mkGetCopy deriveType tyName cons = valD (varP 'getCopy) (normalB $ varE 'contain `appE` getCopyBody) []
    where
      getCopyBody
          = case cons of
              [(_, con)] -> mkGetBody con
              _          -> do
                tagVar <- newName "tag"
                doE [ bindS (varP tagVar) (varE 'getWord8)
                    , noBindS $ caseE (varE tagVar) (
                        [ match (litP $ IntegerL i) (normalB $ mkGetBody con) [] | (i, con) <- cons ] ++
                        [ match wildP (normalB $ varE 'fail `appE` errorMsg tagVar) [] ]) ]
      mkGetBody con
          = do (getFunsDecs, getFuns) <- case deriveType of
                                           Normal -> mkSafeFunctions "safeGet_" 'getSafeGet con
                                           Simple -> return ([], const 'safeGet)
               let getBase = appE (varE 'return) (conE (conName con))
                   getArgs = foldl (\a t -> infixE (Just a) (varE '(<*>)) (Just (varE (getFuns t)))) getBase (conTypes con)
               doE (getFunsDecs ++ [noBindS getArgs])
      errorMsg tagVar = infixE (Just $ strE str1) (varE '(++)) $ Just $
                        infixE (Just tagStr) (varE '(++)) (Just $ strE str2)
          where
            strE = litE . StringL
            tagStr = varE 'show `appE` varE tagVar
            str1 = "Could not identify tag \""
            str2 = concat [ "\" for type "
                          , show tyName
                          , " that has only "
                          , show (length cons)
                          , " constructors.  Maybe your data is corrupted?" ]

mkSafeFunctions :: String -> Name -> Con -> Q ([StmtQ], Type -> Name)
mkSafeFunctions name baseFun con = do let origTypes = conTypes con
                                      realTypes <- mapM followSynonyms origTypes
                                      finish (zip origTypes realTypes) <$> foldM f ([], []) realTypes
    where f (ds, fs) t
              | found     = return (ds, fs)
              | otherwise = do funVar <- newName (name ++ typeName t)
                               return ( bindS (varP funVar) (varE baseFun) : ds
                                      , (t, funVar) : fs )
              where found = any ((== t) . fst) fs
          finish typeList (ds, fs) = (reverse ds, f)
              where f typ = case lookup typ typeList >>= flip lookup fs of
                              Just f  -> f
                              Nothing -> error "mkSafeFunctions: never here"
    -- We can't use a Data.Map because Type isn't a member of Ord =/...

-- | Follow type synonyms.  This allows us to see, for example,
-- that @[Char]@ and @String@ are the same type and we just need
-- to call 'getSafePut' or 'getSafeGet' once for both.
followSynonyms :: Type -> Q Type
followSynonyms t@(ConT name)
    = maybe (return t) followSynonyms =<<
      recover (return Nothing) (do info <- reify name
                                   return $ case info of
                                              TyVarI _ ty            -> Just ty
                                              TyConI (TySynD _ _ ty) -> Just ty
                                              _                      -> Nothing)
followSynonyms (AppT ty1 ty2) = liftM2 AppT (followSynonyms ty1) (followSynonyms ty2)
followSynonyms (SigT ty kind) = liftM (flip SigT kind) (followSynonyms ty)
followSynonyms t              = return t

conSize :: Con -> Int
conSize (NormalC _name args) = length args
conSize (RecC _name recs)    = length recs
conSize InfixC{}             = 2
conSize ForallC{}            = error "Found complex constructor. Cannot derive SafeCopy for it."

conName :: Con -> Name
conName (NormalC name _args) = name
conName (RecC name _recs)    = name
conName (InfixC _ name _)    = name

conTypes :: Con -> [Type]
conTypes (NormalC _name args)       = [t | (_, t)    <- args]
conTypes (RecC _name args)          = [t | (_, _, t) <- args]
conTypes (InfixC (_, t1) _ (_, t2)) = [t1, t2]

typeName :: Type -> String
typeName (VarT name) = nameBase name
typeName (ConT name) = nameBase name
typeName (TupleT n)  = '(' : replicate (n-1) ',' ++ ")"
typeName ArrowT      = "Arrow"
typeName ListT       = "List"
typeName (AppT t u)  = typeName t ++ typeName u
typeName (SigT t _k) = typeName t
typeName _           = "_"
