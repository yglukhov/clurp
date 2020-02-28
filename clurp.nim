import os, macros, strutils

when defined(emscripten):
    proc quoteShellWindows(s: string): string {.compileTime.} =
      ## Quote s, so it can be safely passed to Windows API.
      ## Based on Python's subprocess.list2cmdline
      ## See http://msdn.microsoft.com/en-us/library/17w5ykft.aspx
      let needQuote = {' ', '\t'} in s or s.len == 0

      result = ""
      var backslashBuff = ""
      if needQuote:
        result.add("\"")

      for c in s:
        if c == '\\':
          backslashBuff.add(c)
        elif c == '\"':
          result.add(backslashBuff)
          result.add(backslashBuff)
          backslashBuff.setLen(0)
          result.add("\\\"")
        else:
          if backslashBuff.len != 0:
            result.add(backslashBuff)
            backslashBuff.setLen(0)
          result.add(c)

      if needQuote:
        result.add("\"")

    proc quoteShellPosix(s: string): string {.compileTime.} =
      ## Quote ``s``, so it can be safely passed to POSIX shell.
      ## Based on Python's pipes.quote
      const safeUnixChars = {'%', '+', '-', '.', '/', '_', ':', '=', '@',
                             '0'..'9', 'A'..'Z', 'a'..'z'}
      if s.len == 0:
        return "''"

      let safe = s.allCharsInSet(safeUnixChars)

      if safe:
        return s
      else:
        return "'" & s.replace("'", "'\"'\"'") & "'"

    proc quoteShell(s: string): string {.compileTime.} =
      ## Quote ``s``, so it can be safely passed to shell.
      when defined(Windows):
        return quoteShellWindows(s)
      elif defined(posix):
        return quoteShellPosix(s)
      else:
        {.error:"quoteShell is not supported on your system".}
else:
    from osproc import quoteShell

proc clurpCmdLine(thisModule: string, paths: openarray[string], includeDirs: openarray[string]): string {.compileTime.} =
    var clurp = "clurp"
    when defined(windows):
        clurp &= ".cmd"
    result = clurp & " wrap --thisModule=" & quoteShell(thisModule) & " --paths="
    for p in paths: result.add(quoteShell(p) & ":")
    if includeDirs.len > 0:
        result &= " --includes="
        for p in includeDirs: result.add(quoteShell(p) & ":")

proc nimPathWithCPath(thisModuleDir: string, p: string): string =
    result = thisModuleDir / "clurpcache" / p.extractFilename.changeFileExt("nim")

proc isHeaderFile(file: string): bool =
    let ext = file.splitFile.ext
    if ext.len == 0: return
    ext[1 .. ^1] in ["h", "hp", "hpp", "h++"]

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
    # static: echo "args: ", cmdLine
    const cmdLineRes = staticExec(cmdLine, cache = cmdLine)
    # static: echo cmdLineRes
    importClurpPaths(thisModuleDir, paths)

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
            if header in ctx.moduleHeaders: return ""

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
                var cnt = readFile(fullPath)
                ctx.moduleHeaders.incl(header)
                let prevPath = ctx.currentPath
                ctx.currentPath = parentDir(fullPath)
                preprocessIncludes(cnt, ctx)
                ctx.currentPath = prevPath
                let sign = "//CLURP_HEADER_INJECT:" & header.toUpperAscii()
                result = "\l" & sign & "\l"  & cnt.indent(2) & "\l" & sign & "\l"

            else:
                result = c[0]

    proc wrapAUX(thisModule: string, paths: string, includes: string = "") =
        # echo "called wrap for: ", thisModule
        var paths = paths.split(":")
        let thisModuleDir = parentDir(thisModule)

        var c = Context.new()
        c.allHeaders = @[]
        c.includes = includes.split(":")
        for p in paths:
            if p.isHeaderFile: c.allHeaders.add(thisModuleDir / p)
        for p in paths:
            if not p.isHeaderFile:
                var src = readFile(thisModuleDir / p)
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
