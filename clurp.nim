import os, macros, strutils
const emitSources = defined(android)

proc isHeaderFile(file: string): bool =
    let ext = file.splitFile.ext
    if ext.len == 0: return
    ext[1 .. ^1] in ["h", "hp", "hpp", "h++"]

proc nimPathWithCPath(thisModuleDir: string, p: string): string =
    result = thisModuleDir / "clurpcache" / p.extractFilename.changeFileExt("nim")

when emitSources:
    import sequtils
    when defined(emscripten):
        import quote_emcc
    else:
        from osproc import quoteShell

    proc clurpCmdLine(thisModule: string, paths: openarray[string], includeDirs: openarray[string]): string {.compileTime.} =
        var clurp = "clurp"
        when defined(windows) or defined(buildOnWindows):
            clurp &= ".cmd"
            template qs(s: string):string = quoteShellWindows(s)
        else:
            template qs(s: string):string = quoteShell(s)
        result = clurp & " wrap " & qs("--thisModule=" & thisModule) & " " &
            qs("--paths=" & paths.join(":"))
        if includeDirs.len > 0:
            result.add(" " & qs("--includes=" & includeDirs.join(":")))

    macro importClurpPaths(thisModuleDir: static[string], paths: openarray[string]): untyped =
        result = newNimNode(nnkImportStmt)
        for p in paths:
            let pp = $p
            if not pp.isHeaderFile:
                result.add(newLit(nimPathWithCPath(thisModuleDir, pp)))

    template clurp*(paths: static[openarray[string]], includeDirs: static[openarray[string]] = [""]) =
        const thisModule = instantiationInfo(fullPaths = true).filename
        const thisModuleDir = parentDir(thisModule)
        const cmdLine = clurpCmdLine(thisModule, paths, includeDirs)
        const res = gorgeEx(cmdLine, cache = cmdLine)
        when res.exitCode != 0:
            const env = getEnv("PATH")
            {.error: "\nGorge failed command: " & cmdLine & "\nOutput:" & res.output & "\nProbably clurp not in PATH:" & $env.}

        importClurpPaths(thisModuleDir, paths)

else:
    macro genCompile(moduleDir: static[string], paths: static[openarray[string]], includes: static[openarray[string]]): untyped =
        result = newNimNode(nnkStmtList)
        for p in paths:
            let lit = newLit(moduleDir / p)
            result.add quote do:
                {.compile: `lit`.}

        for i in includes:
            let lit = newLit(i)
            result.add quote do:
                {.passC: "-I" & `lit`.}

    template clurp*(paths: static[openarray[string]], includeDirs: static[openarray[string]] = [""]) =
        const thisModuleDir = instantiationInfo(fullPaths = true).filename.parentDir()
        genCompile(thisModuleDir, paths, includeDirs)

when isMainModule:
    import cligen
    import pegs, sets

    proc isCppFile(file: string): bool =
        let ext = file.splitFile.ext
        if ext.len == 0: return
        ext[1 .. ^1] in ["cp", "cpp", "c++", "cc"]

    let includePattern = peg""" { "#" \s* "include" \s* \" {[^"]*} \" } """

    proc normalizedIncludePath(p: string): string =
        let n = p.find("./")
        if n == -1:
            result = p
        else:
            result = p[n + 2 .. ^1]
            # echo "p: ", p, " normalized: ", result

    type Context = ref object
        moduleHeaders: HashSet[string]
        currentPath: string
        includes: seq[string]
        allHeaders: seq[string]

    proc preprocessIncludes(content: var string, ctx: Context) =
        # echo "try process includes ", content.match(includePattern)
        content = content.replace(includePattern) do(m: int, n: int, c: openArray[string]) -> string:
            let header = normalizedIncludePath(c[1])
            # echo "process header ", c, " h ", header
            if header in ctx.moduleHeaders or header.len == 0: return ""

            var fullPath = ""
            for p in ctx.allHeaders:
                if p.endsWith(header):
                    fullPath = p
                    break

            if fullPath.len == 0 and ctx.includes.len > 0:
                for incl in ctx.includes:
                    if fileExists(incl / header):
                        fullPath = incl / header

                if fullPath.len == 0 and fileExists(ctx.currentPath / header):
                    fullPath = ctx.currentPath / header

            if fullPath.len > 0:
                var cnt = try: readFile(fullPath)
                    except: raise newException(Exception, "Can't open header file: " & fullPath)
                ctx.moduleHeaders.incl(header)
                let prevPath = ctx.currentPath
                ctx.currentPath = parentDir(fullPath)
                preprocessIncludes(cnt, ctx)
                ctx.currentPath = prevPath
                let sign = "//CLURP_HEADER_INJECT:" & header.toUpperAscii()
                result = "\l" & sign & "\l"  & cnt.indent(2) & "\l" & sign & "\l"

            else:
                result = c[0]

    proc wrapAUX(thisModule: string, paths: string, includes: string = ""):int =
        # echo "called wrap for: ", thisModule
        var paths = paths.split(":")
        let thisModuleDir = parentDir(thisModule)

        var c = Context.new()
        c.allHeaders = @[]
        for i in includes.split(":"):
            # TODO: It seems there's a bug on windows. `i` is relative, but should be absolute. The following `if` is a workaround.
            if i.isAbsolute:
                c.includes.add(i)
            else:
                c.includes.add(thisModuleDir / i)
        for p in paths:
            if p.isHeaderFile: c.allHeaders.add(thisModuleDir / p)
        for p in paths:
            if not p.isHeaderFile:
                var src = try: readFile(thisModuleDir / p)
                    except: raise newException(Exception, "Can't open source file: " & thisModuleDir / p)
                c.currentPath = parentDir(thisModuleDir / p)
                c.moduleHeaders = initHashSet[string]()
                preprocessIncludes(src, c)
                doAssert(c.currentPath == parentDir(thisModuleDir / p), "currentPath broken")
                var dst = "{.used.}\n{.emit:\"\"\"\l"
                dst &= src
                dst &= "\"\"\".}\l"
                if p.isCppFile:
                    dst &= "proc nimForceCppCompiler() {.nodecl, importcpp: \"/*cpp()*/\".}\l"
                    dst &= "nimForceCppCompiler()\l"
                let dstPath = nimPathWithCPath(thisModuleDir, p)
                createDir(parentDir(dstPath))
                writeFile(dstPath, dst)

    dispatchMulti([wrapAUX, cmdName = "wrap"])
