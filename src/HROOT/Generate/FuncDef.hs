module HROOT.Generate.FuncDef where

import Control.Applicative hiding (Const)

import HROOT.Generate.CType
import HROOT.Generate.Function
import HROOT.Generate.Class
import HROOT.Generate.Util 


-- Function Declaration and Definition

funcToDecl :: Class -> Function -> String 
funcToDecl c func 
  | (not.isNewFunc) func =  
    let tmpl = "$returntype$ Type ## _$funcname$ ( $args$ )" 
    in  render tmpl [ ("returntype", rettypeToString (genericFuncRet c func))  
                    , ("funcname", aliasedFuncName c func) 
                    , ("args", argsToString (genericFuncArgs func)) ] 
  | otherwise = 
    let tmpl = "$returntype$ Type ## _$funcname$ ( $args$ )" 
    in  render tmpl [ ("returntype", rettypeToString (genericFuncRet c func))  
                  , ("funcname",  aliasedFuncName c func) 
                  , ("args", argsToStringNoSelf (genericFuncArgs func)) ] 
  

funcsToDecls :: Class -> [Function] -> String 
funcsToDecls c = intercalateWith connSemicolonBSlash (funcToDecl c)


funcToDef :: Class -> Function -> String
funcToDef c func 
  | not (isNewFunc func) = 
    let declstr = funcToDecl c func
        callstr = "to_nonconst<Type,Type ## _t>(p)->" 
                  ++ (func_name func) ++ "("
                  ++ argsToCallString (genericFuncArgs func)   
                  ++ ")"
        returnstr = case (genericFuncRet c func) of          
          Void -> callstr ++ ";"
          SelfType -> "return to_nonconst<Type ## _t, Type>((Type *)" ++ callstr ++ ") ;"
          (CT _ctyp _isconst) -> "return "++callstr++";" 
          (CPT (CPTClass str) _) -> "return to_nonconst<"++str++"_t,"++str
                                    ++">(("++str++"*)"++callstr++");"
    in  intercalateWith connBSlash id [declstr, "{", returnstr, "}"] 
  | otherwise = 
    let declstr = funcToDecl c func
        callstr = "(" ++ argsToCallString (genericFuncArgs func) ++ ")"
        returnstr = "Type * newp = new Type " ++ callstr ++ "; \\\nreturn to_nonconst<Type ## _t, Type >(newp);"
    in  intercalateWith connBSlash id [declstr, "{", returnstr, "}"] 

funcsToDefs :: Class -> [Function] -> String
funcsToDefs c = intercalateWith connBSlash (funcToDef c)





