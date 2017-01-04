import os, macros, strutils, tables

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

proc clurpCmdLine(thisModule: string, paths: openarray[string]): string {.compileTime.} =
    result = "clurp wrap " & quoteShell(thisModule) & " "
    for p in paths: result.add(quoteShell(p) & " ")

proc nimPathWithCPath(thisModuleDir: string, p: string): string =
    result = thisModuleDir / "clurpcache" / p.extractFilename.changeFileExt("nim")

proc isHeaderFile(file: string): bool =
    let ext = file.splitFile.ext[1 .. ^1]
    ext in ["h", "hp", "hpp", "h++"]

macro importClurpPaths(thisModuleDir: static[string], paths: openarray[string]): untyped =
    result = newNimNode(nnkImportStmt)
    for p in paths:
        let pp = $p
        if not pp.isHeaderFile:
            result.add(newLit(nimPathWithCPath(thisModuleDir, pp)))

template clurp*(paths: static[openarray[string]]) =
    const thisModule = instantiationInfo(fullPaths = true).filename
    const thisModuleDir = parentDir(thisModule)
    const cmdLine = clurpCmdLine(thisModule, paths)
    #static: echo cmdLine
    const cmdLineRes = staticExec(cmdLine, cache = cmdLine)
    #static: echo "RES: ", cmdLine
    importClurpPaths(thisModuleDir, paths)

when isMainModule:
    import cligen
    import pegs

    proc isCppFile(file: string): bool =
        let ext = file.splitFile.ext[1 .. ^1]
        ext in ["cp", "cpp", "c++", "cc"]

    let includePattern = peg""" { "#" \s* "include" \s* \" {[^"]*} \" } """

    proc normalizedIncludePath(p: string): string =
        let n = p.find("./")
        if n == -1:
            result = p
        else:
            result = p[n + 2 .. ^1]
            #echo "p: ", p, " normalized: ", result

    type Context = ref object
        allHeaders: seq[string]
        includedHeaders: seq[string]

    proc alreadyIncluded(c: Context, header: string): bool =
        for p in c.includedHeaders:
            if p.endsWith(header): return true

    proc preprocessIncludes(content: var string, ctx: Context) =
        content = content.replace(includePattern) do(m: int, n: int, c: openArray[string]) -> string:
            let header = normalizedIncludePath(c[1])
            var fullPath = ""
            for p in ctx.allHeaders:
                if p.endsWith(header):
                    fullPath = p
                    break

            if fullPath.len > 0:
                if ctx.alreadyIncluded(header):
                    result = ""
                else:
                    var cnt = readFile(fullPath)
                    ctx.includedHeaders.add(fullPath)
                    preprocessIncludes(cnt, ctx)
                    discard ctx.includedHeaders.pop()
                    result = "\l" & cnt & "\l"
            else:
                result = c[0]

    proc wrap(thisModule: string, paths: seq[string]) =
        # echo "called wrap for: ", thisModule
        let thisModuleDir = parentDir(thisModule)

        var c = Context.new()
        c.allHeaders = @[]
        for p in paths:
            if p.isHeaderFile: c.allHeaders.add(thisModuleDir / p)
        c.includedHeaders = @[]

        for p in paths:
            if not p.isHeaderFile:
                var src = readFile(thisModuleDir / p)
                preprocessIncludes(src, c)
                var dst = "{.emit:\"\"\"\l"
                dst &= src
                dst &= "\"\"\".}\l"
                if p.isCppFile:
                    dst &= "proc nimForceCppCompiler() {.nodecl, importcpp: \"/*cpp()*/\".}\l"
                    dst &= "nimForceCppCompiler()\l"
                let dstPath = nimPathWithCPath(thisModuleDir, p)
                createDir(parentDir(dstPath))
                writeFile(dstPath, dst)

    dispatchMulti([wrap])
