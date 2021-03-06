{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Code.HsFrontEnd
-- Copyright   : (c) 2011-2017 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Code.HsFrontEnd where

import           Control.Monad.State
import           Control.Monad.Reader
import           Data.List
import           Data.Monoid                             ( (<>) )
import           Language.Haskell.Exts.Build             ( app, binds, doE, letE, letStmt
                                                         , name, pApp
                                                         , qualStmt, strE, tuple
                                                         )
import           Language.Haskell.Exts.Syntax            ( Asst(..), Binds(..), Boxed(..), Bracket(..)
                                                         , ClassDecl(..), DataOrNew(..), Decl(..)
                                                         , Exp(..), ExportSpec(..)
                                                         , ImportDecl(..), InstDecl(..), Literal(..)
                                                         , Name(..), Namespace(..), Pat(..)
                                                         , QualConDecl(..), Stmt(..)
                                                         , Type(..), TyVarBind (..)
                                                         )
-- import           Language.Haskell.Exts.SrcLoc            ( noLoc )
import           System.FilePath                         ((<.>))
-- 
import           FFICXX.Generate.Type.Class
import           FFICXX.Generate.Type.Annotate
import           FFICXX.Generate.Type.Module
import           FFICXX.Generate.Util
import           FFICXX.Generate.Util.HaskellSrcExts



mkComment :: Int -> String -> String
mkComment indent str 
  | (not.null) str = 
    let str_lines = lines str
        indentspace = replicate indent ' ' 
        commented_lines = 
          (indentspace <> "-- | "<>head str_lines) : map (\x->indentspace <> "--   "<>x) (tail str_lines)
     in unlines commented_lines 
  | otherwise = str                

mkPostComment :: String -> String
mkPostComment str 
  | (not.null) str = 
    let str_lines = lines str 
        commented_lines = 
          ("-- ^ "<>head str_lines) : map (\x->"--   "<>x) (tail str_lines)
     in unlines commented_lines 
  | otherwise = str                


genHsFrontDecl :: Class -> Reader AnnotateMap (Decl ())
genHsFrontDecl c = do
  -- for the time being, let's ignore annotation.
  -- amap <- ask  
  -- let cann = maybe "" id $ M.lookup (PkgClass,class_name c) amap 
  let cdecl = mkClass (classConstraints c) (typeclassName c) [mkTBind "a"] body
      sigdecl f = mkFunSig (hsFuncName c f) (functionSignature c f)
      body = map (clsDecl . sigdecl) . virtualFuncs . class_funcs $ c 
  return cdecl

-------------------

genHsFrontInst :: Class -> Class -> [Decl ()]
genHsFrontInst parent child  
  | (not.isAbstractClass) child = 
    let idecl = mkInstance cxEmpty (typeclassName parent) [convertCpp2HS (Just child) SelfType] body
        defn f = mkBind1 (hsFuncName child f) [] rhs Nothing 
          where rhs = app (mkVar (hsFuncXformer f)) (mkVar (hscFuncName child f))
        body = map (insDecl . defn) . virtualFuncs . class_funcs $ parent
    in [idecl]
  | otherwise = []
        

      

---------------------

genHsFrontInstNew :: Class         -- ^ only concrete class 
                  -> Reader AnnotateMap [Decl ()]
genHsFrontInstNew c = do 
  -- amap <- ask
  let fs = filter isNewFunc (class_funcs c)
  return . flip concatMap fs $ \f ->
    let
        -- for the time being, let's ignore annotation.
        -- cann = maybe "" id $ M.lookup (PkgMethod, constructorName c) amap
        -- newfuncann = mkComment 0 cann
        rhs = app (mkVar (hsFuncXformer f)) (mkVar (hscFuncName c f))
    in mkFun (constructorName c) (functionSignature c f) [] rhs Nothing

genHsFrontInstNonVirtual :: Class -> [Decl ()]
genHsFrontInstNonVirtual c =
  flip concatMap nonvirtualFuncs $ \f -> 
    let rhs = app (mkVar (hsFuncXformer f)) (mkVar (hscFuncName c f))
    in mkFun (aliasedFuncName c f) (functionSignature c f) [] rhs Nothing
 where nonvirtualFuncs = nonVirtualNotNewFuncs (class_funcs c)

-----

genHsFrontInstStatic :: Class -> [Decl ()]
genHsFrontInstStatic c =
  flip concatMap (staticFuncs (class_funcs c)) $ \f ->
    let rhs = app (mkVar (hsFuncXformer f)) (mkVar (hscFuncName c f))
    in mkFun (aliasedFuncName c f) (functionSignature c f) [] rhs Nothing

-----

castBody :: [InstDecl ()]
castBody =
  [ insDecl (mkBind1 "cast" [mkPVar "x",mkPVar "f"] (app (mkVar "f") (app (mkVar "castPtr") (app (mkVar "get_fptr") (mkVar "x")))) Nothing)
  , insDecl (mkBind1 "uncast" [mkPVar "x",mkPVar "f"] (app (mkVar "f") (app (mkVar "cast_fptr_to_obj") (app (mkVar "castPtr") (mkVar "x")))) Nothing)
  ]

genHsFrontInstCastable :: Class -> Maybe (Decl ())
genHsFrontInstCastable c 
  | (not.isAbstractClass) c = 
    let iname = typeclassName c
        (_,rname) = hsClassName c
        a = mkTVar "a"
        ctxt = cxTuple [ classA (unqual iname) [a], classA (unqual "FPtr") [a] ]
    in Just (mkInstance ctxt "Castable" [a,tyapp tyPtr (tycon rname)] castBody)
  | otherwise = Nothing

genHsFrontInstCastableSelf :: Class -> Maybe (Decl ())
genHsFrontInstCastableSelf c 
  | (not.isAbstractClass) c = 
    let (cname,rname) = hsClassName c
    in Just (mkInstance cxEmpty "Castable" [tycon cname, tyapp tyPtr (tycon rname)] castBody)
  | otherwise = Nothing


--------------------------

hsClassRawType :: Class -> [Decl ()]
hsClassRawType c =
  [ mkData    rawname [] [] Nothing
  , mkNewtype highname [] [qualConDecl Nothing Nothing (conDecl highname [tyapp tyPtr rawtype])] mderiv
  , mkInstance cxEmpty "FPtr" [hightype]
      [ insType (tyapp (tycon "Raw") hightype) rawtype
      , insDecl (mkBind1 "get_fptr" [pApp (name highname) [mkPVar "ptr"]] (mkVar "ptr") Nothing)
      , insDecl (mkBind1 "cast_fptr_to_obj" [] (con highname) Nothing)
      ]
      
  ]
 where (highname,rawname) = hsClassName c
       hightype = tycon highname
       rawtype = tycon rawname
       mderiv = Just (mkDeriving [i_eq,i_ord,i_show])
         where i_eq   = irule Nothing Nothing (ihcon (unqual "Eq"))
               i_ord  = irule Nothing Nothing (ihcon (unqual "Ord"))
               i_show = irule Nothing Nothing (ihcon (unqual "Show")) 


------------
-- upcast --
------------

genHsFrontUpcastClass :: Class -> [Decl ()]
genHsFrontUpcastClass c = mkFun ("upcast"<>highname) typ [mkPVar "h"] rhs Nothing
  where (highname,rawname) = hsClassName c
        hightype = tycon highname
        rawtype = tycon rawname
        iname = typeclassName c
        a_bind = unkindedVar (name "a")
        a_tvar = mkTVar "a"
        typ = tyForall (Just [a_bind])
                (Just (cxTuple [classA (unqual "FPtr") [a_tvar], classA (unqual iname) [a_tvar]]))
                (tyfun a_tvar hightype)
        rhs = letE [ pbind (mkPVar "fh") (app (mkVar "get_fptr") (mkVar "h")) Nothing
                   , pbind (mkPVarSig "fh2" (tyapp tyPtr rawtype))
                       (app (mkVar "castPtr") (mkVar "fh")) Nothing
                   ]
                   (mkVar "cast_fptr_to_obj" `app` mkVar "fh2")


--------------
-- downcast --
--------------

genHsFrontDowncastClass :: Class -> [Decl ()]
genHsFrontDowncastClass c = mkFun ("downcast"<>highname) typ [mkPVar "h"] rhs Nothing
  where (highname,_rawname) = hsClassName c
        hightype = tycon highname
        iname = typeclassName c
        a_bind = unkindedVar (name "a")
        a_tvar = mkTVar "a"
        typ = tyForall (Just [a_bind])
                (Just (cxTuple [classA (unqual "FPtr") [a_tvar], classA (unqual iname) [a_tvar]]))
                (tyfun hightype a_tvar)
        rhs = letE [ pbind (mkPVar "fh") (app (mkVar "get_fptr") (mkVar "h")) Nothing
                   , pbind (mkPVar "fh2") (app (mkVar "castPtr") (mkVar "fh")) Nothing
                   ] 
                   (mkVar "cast_fptr_to_obj" `app` mkVar "fh2")


------------------------
-- Top Level Function --
------------------------

genTopLevelFuncDef :: TopLevelFunction -> [Decl ()]
genTopLevelFuncDef f@TopLevelFunction {..} = 
    let fname = hsFrontNameForTopLevelFunction f
        (typs,assts) = extractArgRetTypes Nothing False (toplevelfunc_args,toplevelfunc_ret)
        sig = tyForall Nothing (Just (cxTuple assts)) (foldr1 tyfun typs)
        xformerstr = let len = length toplevelfunc_args in if len > 0 then "xform" <> show (len-1) else "xformnull"
        cfname = "c_" <> toLowers fname 
        rhs = app (mkVar xformerstr) (mkVar cfname)
        
    in mkFun fname sig [] rhs Nothing 
genTopLevelFuncDef v@TopLevelVariable {..} = 
    let fname = hsFrontNameForTopLevelFunction v
        cfname = "c_" <> toLowers fname 
        rtyp = (tycon . ctypToHsTyp Nothing) toplevelvar_ret
        sig = tyapp (tycon "IO") rtyp
        rhs = app (mkVar "xformnull") (mkVar cfname)
        
    in mkFun fname sig [] rhs Nothing 


------------
-- Export --
------------

genExport :: Class -> [ExportSpec ()]
genExport c =
    let espec n = if null . (filter isVirtualFunc) $ (class_funcs c) 
                    then eabs nonamespace (unqual n)
                    else ethingall (unqual n)
    in if isAbstractClass c 
       then [ espec (typeclassName c) ]
       else [ ethingall (unqual ((fst.hsClassName) c))
            , espec (typeclassName c)
            , evar (unqual ("upcast" <> (fst.hsClassName) c))
            , evar (unqual ("downcast" <> (fst.hsClassName) c)) ]
            <> genExportConstructorAndNonvirtual c 
            <> genExportStatic c 

-- | constructor and non-virtual function 
genExportConstructorAndNonvirtual :: Class -> [ExportSpec ()]
genExportConstructorAndNonvirtual c = map (evar . unqual) fns
  where fs = class_funcs c
        fns = map (aliasedFuncName c) (constructorFuncs fs 
                                       <> nonVirtualNotNewFuncs fs)

-- | staic function export list 
genExportStatic :: Class -> [ExportSpec ()]
genExportStatic c = map (evar . unqual) fns
  where fs = class_funcs c
        fns = map (aliasedFuncName c) (staticFuncs fs) 


genExtraImport :: ClassModule -> [ImportDecl ()]
genExtraImport cm = map mkImport (cmExtraImport cm)


genImportInModule :: [Class] -> [ImportDecl ()]
genImportInModule = concatMap (\x -> map (\y -> mkImport (getClassModuleBase x<.>y)) ["RawType","Interface","Implementation"])

genImportInFFI :: ClassModule -> [ImportDecl ()]
genImportInFFI = map (\x->mkImport (x <.> "RawType")) . cmImportedModulesForFFI

genImportInInterface :: ClassModule -> [ImportDecl ()]
genImportInInterface m = 
  let modlstraw = cmImportedModulesRaw m
      modlstparent = cmImportedModulesHighNonSource m 
      modlsthigh = cmImportedModulesHighSource m
  in  [mkImport (cmModule m <.> "RawType")]
      <> map (\x -> mkImport (x<.>"RawType")) modlstraw
      <> map (\x -> mkImport (x<.>"Interface")) modlstparent 
      <> map (\x -> mkImportSrc (x<.>"Interface")) modlsthigh

-- |
genImportInCast :: ClassModule -> [ImportDecl ()]
genImportInCast m = [ mkImport (cmModule m <.> "RawType")
                   ,  mkImport (cmModule m <.> "Interface") ]

-- | 
genImportInImplementation :: ClassModule -> [ImportDecl ()]
genImportInImplementation m = 
  let modlstraw' = cmImportedModulesForFFI m
      modlsthigh = nub $ map getClassModuleBase $ concatMap class_allparents (cmClass m)
      modlstraw = filter (not.(flip elem modlsthigh)) modlstraw' 
  in  [ mkImport (cmModule m <.> "RawType")
      , mkImport (cmModule m <.> "FFI")
      , mkImport (cmModule m <.> "Interface")
      , mkImport (cmModule m <.> "Cast") ]
      <> concatMap (\x -> map (\y -> mkImport (x<.>y)) ["RawType","Cast","Interface"]) modlstraw
      <> concatMap (\x -> map (\y -> mkImport (x<.>y)) ["RawType","Cast","Interface"]) modlsthigh

        
genTmplInterface :: TemplateClass -> [Decl ()]
genTmplInterface t =
  [ mkData rname [mkTBind tp] [] Nothing
  , mkNewtype hname [mkTBind tp]
      [ qualConDecl Nothing Nothing (conDecl hname [tyapp tyPtr rawtype]) ] Nothing
  , mkClass cxEmpty (typeclassNameT t) [mkTBind tp] methods
  , mkInstance cxEmpty "FPtr" [ hightype ] fptrbody
  , mkInstance cxEmpty "Castable" [ hightype, tyapp tyPtr rawtype ] castBody
  ]
 where (hname,rname) = hsTemplateClassName t
       tp = tclass_param t
       fs = tclass_funcs t
       rawtype = tyapp (tycon rname) (mkTVar tp)
       hightype = tyapp (tycon hname) (mkTVar tp)
       sigdecl f@TFun {..}    = mkFunSig tfun_name (functionSignatureT t f)
       sigdecl f@TFunNew {..} = mkFunSig ("new"<>tclass_name t) (functionSignatureT t f)
       sigdecl f@TFunDelete = mkFunSig ("delete"<>tclass_name t) (functionSignatureT t f)
       methods = map (clsDecl . sigdecl) fs
       fptrbody = [ insType (tyapp (tycon "Raw") hightype) rawtype
                  , insDecl (mkBind1 "get_fptr" [pApp (name hname) [mkPVar "ptr"]] (mkVar "ptr") Nothing)
                  , insDecl (mkBind1 "cast_fptr_to_obj" [] (con hname) Nothing)
                  ]


genTmplImplementation :: TemplateClass -> [Decl ()]
genTmplImplementation t = concatMap gen (tclass_funcs t)
  where
    gen f = mkFun nh sig [p "nty", p "ncty"] rhs (Just bstmts)
      where nh = case f of
                   TFun {..}    -> "t_" <> tfun_name
                   TFunNew {..} -> "t_" <> "new" <> tclass_name t
                   TFunDelete   -> "t_" <> "delete" <> tclass_name t                   
            nc = case f of
                   TFun {..}    -> tfun_name
                   TFunNew {..} -> "new"
                   TFunDelete   -> "delete"                   
            sig = tycon "Name" `tyfun` (tycon "String" `tyfun` tycon "ExpQ")
            v = mkVar
            p = mkPVar
            tp = tclass_param t
            prefix = tclass_name t
            lit = strE (prefix<>"_"<>nc<>"_")
            lam = lambda [p "n"] ( lit `app` v "<>" `app` v "n") 
            rhs = app (v "mkTFunc") (tuple [v "nty", v "ncty", lam, v "tyf"])
            sig' = functionSignatureTT t f
            bstmts = binds [ mkBind1 "tyf" [mkPVar "n"]
                               (letE [ pbind (p tp) (v "return" `app` (con "ConT" `app` v "n")) Nothing ]
                                  (bracketExp (typeBracket sig')))
                               Nothing 
                           ]


genTmplInstance :: TemplateClass -> [TemplateFunction] -> [Decl ()]
genTmplInstance t fs = mkFun fname sig [p "n", p "ctyp"] rhs Nothing
  where tname = tclass_name t 
        fname = "gen" <> tname <> "InstanceFor"
        p = mkPVar
        v = mkVar
        sig = tycon "Name" `tyfun` (tycon "String" `tyfun` (tyapp (tycon "Q") (tylist (tycon "Dec"))))

        nfs = zip ([1..] :: [Int]) fs
        rhs = doE (map genstmt nfs <> [letStmt (lststmt nfs), qualStmt retstmt])

        genstmt (n,TFun    {..}) = generator (p ("f"<>show n))
                                   (v "mkMember" `app` strE tfun_name
                                                 `app` v ("t_" <> tfun_name)
                                                 `app` v "n"
                                                 `app` v "ctyp"
                                   )
        genstmt (n,TFunNew {..}) = generator (p ("f"<>show n)) 
                                   (v "mkNew"    `app` strE ("new" <> tname)
                                                 `app` v ("t_new" <> tname)
                                                 `app` v "n"
                                                 `app` v "ctyp"
                                   )
        genstmt (n,TFunDelete)   = generator (p ("f"<>show n)) 
                                   (v "mkDelete" `app` strE ("delete"<>tname)
                                                 `app` v ("t_delete" <> tname)
                                                 `app` v "n"
                                                 `app` v "ctyp"
                                   )                                   
        lststmt xs = [ pbind (p "lst") (list (map (v . (\n->"f"<>show n) . fst) xs)) Nothing ]
        retstmt = v "return"
                  `app` list [ v "mkInstance"
                               `app` list []
                               `app` (con "AppT"
                                      `app` (v "con" `app` strE (typeclassNameT t))
                                      `app` (con "ConT" `app` (v "n"))
                                     )
                               `app` (v "lst")
                             ] 

