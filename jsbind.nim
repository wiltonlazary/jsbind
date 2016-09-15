import macros, strutils, logging

proc unpackedName*(someProc: NimNode): string {.compileTime.} =
    var res = someProc.name
    if not res.isNil and res.kind == nnkPostfix:
        res = res[1]
    if not res.isNil and res.kind == nnkAccQuoted:
        return $res[0] & $res[1]
    result = $res

when defined(js):
    type JSObj* = ref object of RootObj
    type jsstring* = cstring

    proc addPragma*(someProc, pragma: NimNode) =
        ## Adds pragma to callable definition
        var pragmaNode = someProc.pragma
        if pragmaNode.isNil or pragmaNode.kind == nnkEmpty:
            pragmaNode = newNimNode(nnkPragma)
            someProc.pragma = pragmaNode
        pragmaNode.add(pragma)

    macro jsimportWithName*(name: string = nil, p: untyped): typed =
        p.addPragma(newNimNode(nnkExprColonExpr).add(
            newIdentNode("importcpp"),
            newLit($name)))
        result = p

    macro jsimport*(p: untyped): typed =
        p.addPragma(newIdentNode("importcpp"))
        result = p

    macro jsimportg*(p: untyped): typed =
        p.addPragma(newIdentNode("importc"))
        result = p

    macro jsimportgWithName*(name: string, p: untyped): typed =
        p.addPragma(newNimNode(nnkExprColonExpr).add(
            newIdentNode("importc"),
            newLit($name)))
        result = p

    macro jsimportProp*(p: untyped): untyped =
        let n = p.unpackedName
        if n.endsWith("="):
            p.addPragma(newNimNode(nnkExprColonExpr).add(
                newIdentNode("importcpp"),
                newLit("#." & $n & "@")))
        else:
            p.addPragma(newNimNode(nnkExprColonExpr).add(
                newIdentNode("importcpp"),
                newLit("#." & $n)))
        result = p

    template jsRef*(e: typed) = discard
    template jsUnref*(e: typed) = discard

elif defined(emscripten):
    import jsbind.emscripten

    type JSObj* = ref object of RootObj
        p: cint
    type jsstring* = string

    proc nimem_ps(s: cint): string {.EMSCRIPTEN_KEEPALIVE.} =
        result = newString(s)

    proc nimem_sb(s: string): pointer {.EMSCRIPTEN_KEEPALIVE.} =
        result = unsafeAddr s[0]

    proc nimem_fs(s: string) {.EMSCRIPTEN_KEEPALIVE.} =
        var i = 0
        while ord(s[i]) != 0: inc i
        let a = unsafeAddr(s)
        a[].setLen(i)

    proc nimem_ee(c: cstring) {.EMSCRIPTEN_KEEPALIVE.} =
        # Log error
        error c

    proc initEmbindEnv() =
        discard EM_ASM_INT("""
        var g = ((typeof window) === 'undefined') ? global : window;
        g._nimem_o = {};
        g._nimem_o[0] = null;
        g._nimem_i = 0;
        g._nimem_w = function(o) {
            // Wrap a JS object `o` so that it can be used in emscripten
            // functions. Returns an int handle to the wrapped object.
            if (o === null) return 0;
            g._nimem_o[++g._nimem_i] = o;
            return g._nimem_i;
        };

        g._nimem_s = function(s) {
            // Wrap JS string `s` to nim string. Returns address of the
            // resulting nim string.
            var l = s.length * 4;
            var b = _nimem_ps(l*4);
            stringToUTF8(s, _nimem_sb(b), l);
            _nimem_fs(b);
            return b;
        };

        g._nimem_e = function(e) {
            // This function is called when JS (not native) exception is thrown
            // from within emscripten function passed as callback to some JS entity.
            // The main purpose is to log such exception with nim logger.
            var s = "Exception: " + (e.message !== undefined) ? e.message : "Unknown";
            if (e.stack !== undefined) s += ": " + e.stack;
            var c = allocate(intArrayFromString(s), 'i8', ALLOC_NORMAL);
            _nimem_ee(c);
            _free(c);
            throw e;
        }
        """)

    initEmbindEnv()

    {.push stackTrace: off.}
    proc finalizeEmbindObject(o: JSObj) =
        discard EM_ASM_INT("delete _nimem_o[$0]", o.p)

    proc newEmbindObject(t: typedesc, emref: cint): t {.inline.} =
        result.new(cast[proc(o: t){.nimcall.}](finalizeEmbindObject))
        result.p = emref

    proc globalEmbindObject*(t: typedesc, name: static[string]): t {.inline.} =
        let o = EM_ASM_INT("return _nimem_w(" & name & ")")
        newEmbindObject(t, o)

    proc nimem_new(p: cint): JSObj {.EMSCRIPTEN_KEEPALIVE.} =
        newEmbindObject(JSObj, p)

    {.pop.}

    template toEmPtr(s: cstring): cstring = cstring(s)
    template toEmPtr(s: int | uint | cint | int32 | uint32 | uint16 | int16 | bool): cint = cint(s)
    template toEmPtr(s: JSObj): cint = s.p
    template toEmPtr(s: float | float32 | float64 | cfloat | cdouble): cdouble = cdouble(s)

    proc getClosureAddr(s: proc): pointer {.importc: "&", nodecl.}

    template toEmPtr(s: proc): cint =
        when s is proc {.closure.}:
            block:
                cast[cint](getClosureAddr(s))
        else:
            cast[cint](cast[pointer](s))

    template emTypeToNimType(T: typedesc, v: untyped) =
        let tmp = v
        when T is JSObj:
            if tmp != 0: result = newEmbindObject(T, tmp)
        elif T is string:
            result = cast[string](tmp)
        else:
            result = T(tmp)

    template emAsmImpl(cintCall: untyped, cdoubleCall: untyped): stmt =
        when declared(result):
            type R = type(result)
            when R is (float32 or float64 or float):
                let tmp = cdoubleCall
                result = R(tmp)
            else:
                emTypeToNimType(R, cintCall)
        else:
            discard cintCall

    proc getArgNames(p: NimNode): NimNode =
        result = newNimNode(nnkStmtList)
        let parms = p.params
        for i in 1 ..< parms.len:
            let identDefs = parms[i]
            for j in 0 ..< identDefs.len - 2:
                result.add(identDefs[j])

    macro forEveryArg(p: typed, s: untyped): untyped =
        result = newNimNode(nnkBracket)
        let t = getType(p)
        for i in 2 ..< t.len:
            result.add(newCall(s, newLit(i - 2), newCall("type", getType(t[i]))))

    template jsConvertJSToNim(t: typedesc, code: string): string =
        when t is JSObj:
            "_nimem_w(" & code & ")"
        elif t is string:
            "_nimem_s(" & code & ")"
        else:
            code

    template packResultCode(code: string): string =
        ## Given the JS code that
        when declared(result):
            "return " & jsConvertJSToNim(type(result), code)
        else:
            code

    template jsArgSignature(i: int, t: typedesc): string =
        when t is (cfloat or cdouble or float32 or float64 or float): "d"
        else: "i"

    template jsArgDef(i: int, t: typedesc): string = "a" & $i

    template jsArgFwd(i: int, t: typedesc): string =
        when t is JSObj:
            "_nimem_new(" & jsConvertJSToNim(t, "a" & $i) & ")"
        else:
            jsConvertJSToNim(t, "a" & $i)

    const wrapDynCallInTryCatch = true

    proc unpackFunctionArg(jsParamName: string, argsSigParts, argDefsParts, argForwardParts: openarray[string], isClosure: bool): string {.compileTime.} =
        let argsSig = "v" & argsSigParts.join()
        let argDefs = argDefsParts.join(",")
        let argForwards = argForwardParts.join(",")
        var dynCall = ""
        if isClosure:
            let argForwardsWithEnv = (@argForwardParts & "b").join(",")
            dynCall = "Runtime.dynCall(b?'" & argsSig & "i':'" & argsSig & "',a,b?[" & argForwardsWithEnv & "]:[" & argForwards & "])"
        else:
            dynCall = "Runtime.dynCall('" & argsSig & "'," & jsParamName & ",[" & argForwards & "])"

        if wrapDynCallInTryCatch:
            dynCall = "try{" & dynCall & "}catch(e){_nimem_e(e)}"

        if isClosure:
            return "function(a,b){return a?function(" & argDefs & "){" & dynCall & "}:null}(getValue(" & jsParamName & ", '*'), getValue(" & jsParamName & "+4, '*'))"
        else:
            return jsParamName & "?function(" & argDefs & "){" & dynCall & "}:null"

    template unpackArgCode(index: int, arg: typed): string =
        ## Returns the chunk of JS code, representing the arg
        const jsParamName = "$" & $index

        when type(arg) is (string | cstring):
            "UTF8ToString(" & jsParamName & ")"
        elif type(arg) is JSObj:
            "_nimem_o[" & jsParamName & "]"
        elif type(arg) is (proc):
            const fn = unpackFunctionArg(jsParamName,
                forEveryArg(arg, jsArgSignature),
                forEveryArg(arg, jsArgDef),
                forEveryArg(arg, jsArgFwd),
                type(arg) is proc {.closure.})
            fn
        else:
            jsParamName

    proc wrapIntoPragmaScope(n: NimNode, option, value: string): NimNode =
        result = newNimNode(nnkStmtList)
        result.add(newNimNode(nnkPragma).add(newIdentNode("push"), newNimNode(nnkExprColonExpr).add(newIdentNode(option), newIdentNode(value))))
        result.add(n)
        result.add(newNimNode(nnkPragma).add(newIdentNode("pop")))

    proc jsImportAux(p: NimNode, infix: bool, pName: string, property: bool = false): NimNode =
        let argNames = getArgNames(p)
        result = p

        var setter = false
        var ppName = pName
        if pName.endsWith("="):
            ppName = pName[0 .. ^2]
            setter = true
        let procName = newLit(ppName)

        let cintCall = newCall(bindSym"EM_ASM_INT", newLit(""))
        let cdoubleCall = newCall(bindSym"EM_ASM_DOUBLE", newLit(""))

        var codeNode: NimNode
        var argIndexStart = 0
        if infix:
            inc argIndexStart
            let firstArg = argNames[0]

            cintCall.add(newCall(bindSym"toEmPtr", firstArg))
            cdoubleCall.add(newCall(bindSym"toEmPtr", firstArg))

            codeNode = quote do:
                unpackArgCode(0, `firstArg`)

            codeNode = quote do:
                `codeNode` & "." & `procName`
            if setter:
                codeNode = quote do:
                    `codeNode` & "="
            elif not property:
                codeNode = quote do:
                    `codeNode` & "("
        else:
            codeNode = quote do:
                `procName` & "("

        for i in argIndexStart ..< argNames.len:
            let argName = argNames[i]
            cintCall.add(newCall(bindSym"toEmPtr", argName))
            cdoubleCall.add(newCall(bindSym"toEmPtr", argName))
            if i != argIndexStart:
                codeNode = quote do:
                    `codeNode` & ","
            let iLit = newLit(i)
            codeNode = quote do:
                `codeNode` & unpackArgCode(`iLit`, `argName`)

        if not property:
            codeNode = quote do:
                `codeNode` & ")"
        codeNode = quote do:
            packResultCode(`codeNode`)

        cintCall[1] = codeNode
        cdoubleCall[1] = codeNode

        p.body = newCall(bindSym"emAsmImpl", cintCall, cdoubleCall)
        p.addPragma(newIdentNode("inline"))
        #echo repr(p)
        result = wrapIntoPragmaScope(p, "stackTrace", "off")

    template jsRef*(e: typed) =
        when e is (proc):
            let re = rawEnv(e)
            if not re.isNil:
                GC_ref(cast[ref RootObj](re))
        else:
            GC_ref(e)

    template jsUnref*(e: typed) =
        when e is (proc):
            let re = rawEnv(e)
            if not re.isNil:
                GC_unref(cast[ref RootObj](re))
        else:
            GC_unref(e)

    macro jsimportWithName*(name: string = nil, p: untyped): typed =
        jsImportAux(p, true, $name)

    macro jsimport*(p: untyped): typed =
        jsImportAux(p, true, p.unpackedName)

    macro jsimportg*(p: untyped): typed =
        jsImportAux(p, false, p.unpackedName)

    macro jsimportgWithName*(name: string, p: untyped): typed =
        jsImportAux(p, false, $name)

    macro jsimportProp*(p: untyped): typed =
        jsImportAux(p, true, p.unpackedName, true)

proc processJSException() =
    let e = getCurrentException()
    when defined(js):
        var stack: string
        if e.isNil:
            var cstack: cstring
            {.emit: """
            if (lastJSError.stack !== undefined) {
                `cstack` = lastJSError.stack;
            }
            """.}
            if cstack.isNil:
                stack = "No stack trace available"
            else:
                stack = $cstack
        else:
            stack = getStackTrace(e)
    else:
        let stack = getStackTrace(e)
    error "Exception: ", getCurrentExceptionMsg(), "\l", stack

template handleJSExceptions*(body: untyped) =
    try:
        body
    except:
        processJSException()
        raise

when false:
    ## Usage example:
    type Console* = ref object of JSObj # Declare some JS type
    proc log*(c: Console, s: cstring) {.jsimport.} # Declare method
    proc anotherLog*(c: Console, s: cstring) {.jsimportWithName: "log".} # Declare method with different name in js

    when defined(js):
        var console {.importc, nodecl.}: Console
    elif defined(emcsripten):
        var console = globalEmbindObject(Console, "console")
    console.log("Hello, world!");