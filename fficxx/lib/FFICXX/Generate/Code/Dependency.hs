{-# LANGUAGE RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Code.Dependency
-- Copyright   : (c) 2011-2017 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Code.Dependency where

--
-- fficxx generates one module per one C++ class, and C++ class depends on other classes,
-- so we need to import other modules corresponding to C++ classes in the dependency list.
-- Calculating the import list from dependency graph is what this module does.

-- Previously, we have only `Class` type, but added `TemplateClass` recently. Therefore
-- we have to calculate dependency graph for both types of classes. So we needed to change
-- `Class` to `Either TemplateClass Class` in many of routines that calculates module import
-- list.

-- `Dep4Func` contains a list of classes (both ordinary and template types) that is needed
-- for the definition of a member function.
-- The goal of `extractClassDep...` functions are to extract Dep4Func, and from the definition
-- of a class or a template class, we get a list of `Dep4Func`s and then we deduplicate the
-- dependency class list and finally get the import list for the module corresponding to
-- a given class.   
-- 

import           Data.Either               ( rights )
import           Data.Function             ( on )
import qualified Data.HashMap.Strict as HM
import           Data.List 
import           Data.Maybe
import           Data.Monoid               ( (<>) )
import           System.FilePath 
--
import           FFICXX.Generate.Type.Class
import           FFICXX.Generate.Type.Module
import           FFICXX.Generate.Type.PackageInterface
--
import           Debug.Trace


-- utility functions

getclassname = either tclass_name class_name

getcabal = either tclass_cabal class_cabal

getparents = either (const []) (map Right . class_parents) 

getmodulebase = either getTClassModuleBase getClassModuleBase

-- |
extractClassFromType :: Types -> Maybe (Either TemplateClass Class)
extractClassFromType Void                     = Nothing
extractClassFromType SelfType                 = Nothing
extractClassFromType (CT _ _)                 = Nothing
extractClassFromType (CPT (CPTClass c) _)     = Just (Right c)
extractClassFromType (CPT (CPTClassRef c) _)  = Just (Right c)
extractClassFromType (CPT (CPTClassCopy c) _) = Just (Right c)
extractClassFromType (TemplateApp t _ _)      = Just (Left t)
extractClassFromType (TemplateAppRef t _ _)   = Just (Left t)
extractClassFromType (TemplateType t)         = Just (Left t)
extractClassFromType (TemplateParam _)        = Nothing


-- | class dependency for a given function 
data Dep4Func = Dep4Func { returnDependency :: Maybe (Either TemplateClass Class)
                         , argumentDependency :: [(Either TemplateClass Class)] }


-- | 
extractClassDep :: Function -> Dep4Func 
extractClassDep (Constructor args _)  = Dep4Func Nothing (catMaybes (map (extractClassFromType.fst) args))
extractClassDep (Virtual ret _ args _) = 
    Dep4Func (extractClassFromType ret) (mapMaybe (extractClassFromType.fst) args)
extractClassDep (NonVirtual ret _ args _) =
    Dep4Func (extractClassFromType ret) (mapMaybe (extractClassFromType.fst) args)
extractClassDep (Static ret _ args _) = 
    Dep4Func (extractClassFromType ret) (mapMaybe (extractClassFromType.fst) args)
extractClassDep (Destructor _) = 
    Dep4Func Nothing [] 


extractClassDepForTmplFun :: TemplateFunction -> Dep4Func 
extractClassDepForTmplFun (TFun ret  _ _ args _) = 
    Dep4Func (extractClassFromType ret) (mapMaybe (extractClassFromType.fst) args)
extractClassDepForTmplFun (TFunNew args) =
    Dep4Func Nothing (mapMaybe (extractClassFromType.fst) args)
extractClassDepForTmplFun TFunDelete = Dep4Func Nothing [] 


extractClassDepForTopLevelFunction :: TopLevelFunction -> Dep4Func 
extractClassDepForTopLevelFunction f = 
    Dep4Func (extractClassFromType ret) (mapMaybe (extractClassFromType.fst) args)
  where ret = case f of 
                TopLevelFunction {..} -> toplevelfunc_ret
                TopLevelVariable {..} -> toplevelvar_ret
        args = case f of
                 TopLevelFunction {..} -> toplevelfunc_args
                 TopLevelVariable {..} -> [] 


-- | 
mkModuleDepRaw :: Either TemplateClass Class -> [Either TemplateClass Class] 
mkModuleDepRaw x@(Right c)
  = (nub . filter (/= x) . mapMaybe (returnDependency.extractClassDep) . class_funcs) c
mkModuleDepRaw x@(Left t)
  = (nub . filter (/= x) . mapMaybe (returnDependency.extractClassDepForTmplFun) . tclass_funcs) t


-- | 
mkModuleDepHighNonSource :: Either TemplateClass Class -> [Either TemplateClass Class] 
mkModuleDepHighNonSource y@(Right c) = 
  let fs = class_funcs c 
      pkgname = (cabal_pkgname . class_cabal) c
      extclasses = (filter (\x-> x /= y && ((/= pkgname) . cabal_pkgname . getcabal) x) . concatMap (argumentDependency.extractClassDep)) fs
      parents = map Right (class_parents c)
  in  nub (parents <> extclasses) 
mkModuleDepHighNonSource y@(Left t) = 
  let fs = tclass_funcs t 
      pkgname = (cabal_pkgname . tclass_cabal) t 
      extclasses = (filter (\x-> x /= y && ((/= pkgname) . cabal_pkgname . getcabal) x) . concatMap (argumentDependency.extractClassDepForTmplFun)) fs
      -- parents = class_parents c 
  in  nub extclasses


-- | 
mkModuleDepHighSource :: Either TemplateClass Class -> [Either TemplateClass Class] 
mkModuleDepHighSource y@(Right c) = 
  let fs = class_funcs c 
      pkgname = (cabal_pkgname . class_cabal) c 
  in  nub . filter (\x-> x /= y && not (x `elem` getparents y) && (((== pkgname) . cabal_pkgname . getcabal) x)) . concatMap (argumentDependency.extractClassDep) $ fs
mkModuleDepHighSource y@(Left t) = 
  let fs = tclass_funcs t
      pkgname = (cabal_pkgname . tclass_cabal) t
  in  nub . filter (\x-> x /= y && not (x `elem` getparents y) && (((== pkgname) . cabal_pkgname . getcabal) x)) . concatMap (argumentDependency.extractClassDepForTmplFun) $ fs

-- | 
mkModuleDepCpp :: Either TemplateClass Class -> [Either TemplateClass Class] 
mkModuleDepCpp y@(Right c) = 
  let fs = class_funcs c 
  in  nub . filter (/= y)  $ 
        mapMaybe (returnDependency.extractClassDep) fs   
        <> concatMap (argumentDependency.extractClassDep) fs
        <> getparents y
mkModuleDepCpp y@(Left t) = 
  let fs = tclass_funcs t
  in  nub . filter (/= y)  $ 
        mapMaybe (returnDependency.extractClassDepForTmplFun) fs   
        <> concatMap (argumentDependency.extractClassDepForTmplFun) fs
        <> getparents y

-- | 
mkModuleDepFFI4One :: Either TemplateClass Class -> [Either TemplateClass Class] 
mkModuleDepFFI4One (Right c) = 
  let fs = class_funcs c 
  in mapMaybe (returnDependency.extractClassDep) fs <> concatMap (argumentDependency.extractClassDep) fs 
mkModuleDepFFI4One (Left t) = 
  let fs = tclass_funcs t 
  in mapMaybe (returnDependency.extractClassDepForTmplFun) fs <>
     concatMap (argumentDependency.extractClassDepForTmplFun) fs 


-- | 
mkModuleDepFFI :: Either TemplateClass Class -> [Either TemplateClass Class] 
mkModuleDepFFI y@(Right c) = 
  let ps = map Right (class_allparents c)
      alldeps' = (concatMap mkModuleDepFFI4One ps) <> mkModuleDepFFI4One y
  in nub (filter (/= y) alldeps')
mkModuleDepFFI y@(Left t) = [] 

     
mkClassModule :: (Class->([Namespace],[HeaderName]))
              -> [(String,[String])]
              -> Class 
              -> ClassModule 
mkClassModule mkincheaders extra c =
  ClassModule (getClassModuleBase c) [c] (map (mkCIH mkincheaders) [c]) highs_nonsource
              raws highs_source ffis extraimports

  where highs_nonsource = (map getmodulebase . mkModuleDepHighNonSource) (Right c)
        raws = (map getmodulebase . mkModuleDepRaw) (Right c)
        highs_source = (map getmodulebase . mkModuleDepHighSource) (Right c)
        ffis = (map getmodulebase . mkModuleDepFFI) (Right c)
        extraimports = fromMaybe [] (lookup (class_name c) extra)



mkClassNSHeaderFromMap :: HM.HashMap String ([Namespace],[HeaderName]) -> Class -> ([Namespace],[HeaderName])
mkClassNSHeaderFromMap m c = fromMaybe ([],[]) (HM.lookup (class_name c) m)


mkTCM :: (TemplateClass,HeaderName) -> TemplateClassModule 
mkTCM (t,hdr) = TCM  (getTClassModuleBase t) [t] [TCIH t hdr]


mkPackageConfig
  :: (String,Class->([Namespace],[HeaderName])) -- ^ (package name,mkIncludeHeaders)
  -> ([Class],[TopLevelFunction],[(TemplateClass,HeaderName)],[(String,[String])])
  -> [AddCInc]
  -> [AddCSrc]
  -> PackageConfig
mkPackageConfig (pkgname,mkNS_IncHdrs) (cs,fs,ts,extra) acincs acsrcs = 
  let ms = map (mkClassModule mkNS_IncHdrs extra) cs 
      cmpfunc x y = class_name (cihClass x) == class_name (cihClass y)
      cihs = nubBy cmpfunc (concatMap cmCIH ms)
      -- for toplevel 
      tl_cs1 = concatMap (argumentDependency . extractClassDepForTopLevelFunction) fs 
      tl_cs2 = mapMaybe (returnDependency . extractClassDepForTopLevelFunction) fs 
      tl_cs = nubBy ((==) `on` getclassname) (tl_cs1 <> tl_cs2)
      tl_cihs = catMaybes $ 
        foldr (\c acc-> (find (\x -> (class_name . cihClass) x == getclassname c) cihs):acc) [] tl_cs 
      -- 
      tih = TopLevelImportHeader (pkgname <> "TopLevel") tl_cihs fs
      tcms = map mkTCM ts
      tcihs = concatMap tcmTCIH tcms
  in PkgConfig ms cihs tih tcms tcihs acincs acsrcs


mkHSBOOTCandidateList :: [ClassModule] -> [String]
mkHSBOOTCandidateList ms = nub (concatMap cmImportedModulesHighSource ms)

-- | 
mkPkgHeaderFileName ::Class -> HeaderName
mkPkgHeaderFileName c = 
    HdrName ((cabal_cheaderprefix.class_cabal) c <> class_name c <.> "h")

-- | 
mkPkgCppFileName ::Class -> String 
mkPkgCppFileName c = 
    (cabal_cheaderprefix.class_cabal) c <> class_name c <.> "cpp"

-- | 
mkPkgIncludeHeadersInH :: Class -> [HeaderName]
mkPkgIncludeHeadersInH c =
    let pkgname = (cabal_pkgname . class_cabal) c
        extclasses = (filter ((/= pkgname) . cabal_pkgname . getcabal) . mkModuleDepCpp) (Right c)
        extheaders = nub . map ((<>"Type.h") .  cabal_pkgname . getcabal) $ extclasses  
    in map mkPkgHeaderFileName (class_allparents c) <> map HdrName extheaders

                           

-- | 
mkPkgIncludeHeadersInCPP :: Class -> [HeaderName]
mkPkgIncludeHeadersInCPP = map mkPkgHeaderFileName . rights . mkModuleDepCpp . Right


-- | 
mkCIH :: (Class->([Namespace],[HeaderName]))  -- ^ (mk namespace and include headers)  
      -> Class 
      -> ClassImportHeader
mkCIH mkNSandIncHdrs c = ClassImportHeader c 
                           (mkPkgHeaderFileName c) 
                           ((fst . mkNSandIncHdrs) c)
                           (mkPkgCppFileName c) 
                           (mkPkgIncludeHeadersInH c) 
                           (mkPkgIncludeHeadersInCPP c)
                           ((snd . mkNSandIncHdrs) c)
