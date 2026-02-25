; =============================================================================
; Json.ahk - JSON parser and serializer for AutoHotkey v2
; Vendored for WorkspaceLayoutManager - no external dependencies
; =============================================================================

class JSON {

    ; -------------------------------------------------------------------------
    ; Parse a JSON string into AHK objects:
    ;   JSON objects  -> Map
    ;   JSON arrays   -> Array
    ;   JSON strings  -> String
    ;   JSON numbers  -> Integer or Float
    ;   JSON true     -> 1 (Integer)
    ;   JSON false    -> 0 (Integer)
    ;   JSON null     -> "" (empty String)
    ; -------------------------------------------------------------------------
    static Parse(str) {
        if Type(str) != "String"
            throw Error("JSON.Parse: expected a String, got " . Type(str))
        p := JSON._Parser(str)
        result := p.ParseValue()
        p.SkipWhitespace()
        if p.pos <= p.len
            throw Error("JSON.Parse: unexpected trailing characters at pos " . p.pos)
        return result
    }

    ; -------------------------------------------------------------------------
    ; Stringify an AHK object into a JSON string.
    ;   indent  - indentation string per level (e.g. "  "); "" = compact
    ; Internal _depth tracks recursion level.
    ; -------------------------------------------------------------------------
    static Stringify(obj, indent := "  ", _depth := 0) {
        objType := Type(obj)

        ; --- Map -> JSON object ---
        if obj is Map {
            if obj.Count == 0
                return "{}"
            items := []
            nextInd := JSON._Repeat(indent, _depth + 1)
            curInd  := JSON._Repeat(indent, _depth)
            sep := indent != "" ? ",`n" : ","
            for key, val in obj {
                k := JSON._EscapeString(String(key))
                v := JSON.Stringify(val, indent, _depth + 1)
                items.Push(indent != "" ? nextInd . k . ": " . v : k . ":" . v)
            }
            nl := indent != "" ? "`n" : ""
            return "{" . nl . JSON._Join(items, sep) . nl . curInd . "}"
        }

        ; --- Array -> JSON array ---
        if obj is Array {
            if obj.Length == 0
                return "[]"
            items := []
            nextInd := JSON._Repeat(indent, _depth + 1)
            curInd  := JSON._Repeat(indent, _depth)
            sep := indent != "" ? ",`n" : ","
            for val in obj {
                v := JSON.Stringify(val, indent, _depth + 1)
                items.Push(indent != "" ? nextInd . v : v)
            }
            nl := indent != "" ? "`n" : ""
            return "[" . nl . JSON._Join(items, sep) . nl . curInd . "]"
        }

        ; --- Numbers ---
        if objType == "Integer"
            return String(obj)
        if objType == "Float" {
            ; Avoid scientific notation for small floats
            s := String(obj)
            return s
        }

        ; --- Strings ---
        if objType == "String"
            return JSON._EscapeString(obj)

        ; --- Fallback: null ---
        return "null"
    }

    ; -------------------------------------------------------------------------
    ; Internal helpers
    ; -------------------------------------------------------------------------
    static _EscapeString(str) {
        ; Use Chr(34) for literal " to avoid single-quote/double-quote parsing ambiguity.
        ; All else-if actions are on their own line (AHK v2 requirement for chained if/else).
        dq     := Chr(34)       ; the double-quote character "
        result := dq            ; opening "
        Loop Parse, str {
            ch   := A_LoopField
            code := Ord(ch)
            if ch == dq         ; " → \" in JSON
                result .= "\" . dq
            else if ch == "\"   ; \ → \\ in JSON
                result .= "\\"
            else if code == 8   ; backspace
                result .= "\b"
            else if code == 12  ; form feed
                result .= "\f"
            else if code == 10  ; newline
                result .= "\n"
            else if code == 13  ; carriage return
                result .= "\r"
            else if code == 9   ; tab
                result .= "\t"
            else if code < 32   ; other control chars
                result .= "\u" . Format("{:04x}", code)
            else
                result .= ch
        }
        result .= dq            ; closing "
        return result
    }

    static _Join(arr, sep) {
        result := ""
        for i, v in arr {
            if i > 1
                result .= sep
            result .= v
        }
        return result
    }

    static _Repeat(str, n) {
        result := ""
        Loop n
            result .= str
        return result
    }

    ; =========================================================================
    ; Inner parser class
    ; =========================================================================
    class _Parser {
        __New(str) {
            this.str := str
            this.pos := 1
            this.len := StrLen(str)
        }

        ParseValue() {
            this.SkipWhitespace()
            if this.pos > this.len
                throw Error("JSON: unexpected end of input")
            ch := SubStr(this.str, this.pos, 1)
            if ch == "{"
                return this.ParseObject()
            else if ch == "["
                return this.ParseArray()
            else if ch == Chr(34)   ; "
                return this.ParseString()
            else if ch == "t" || ch == "f"
                return this.ParseBool()
            else if ch == "n"
                return this.ParseNull()
            else if ch == "-" || (Ord(ch) >= 48 && Ord(ch) <= 57)
                return this.ParseNumber()
            throw Error("JSON: unexpected character '" . ch . "' at pos " . this.pos)
        }

        ParseObject() {
            this.Expect("{")
            this.SkipWhitespace()
            obj := Map()
            if SubStr(this.str, this.pos, 1) == "}" {
                this.pos++
                return obj
            }
            loop {
                this.SkipWhitespace()
                key := this.ParseString()
                this.SkipWhitespace()
                this.Expect(":")
                this.SkipWhitespace()
                val := this.ParseValue()
                obj[key] := val
                this.SkipWhitespace()
                ch := SubStr(this.str, this.pos, 1)
                if ch == "}" {
                    this.pos++
                    return obj
                }
                this.Expect(",")
            }
        }

        ParseArray() {
            this.Expect("[")
            this.SkipWhitespace()
            arr := []
            if SubStr(this.str, this.pos, 1) == "]" {
                this.pos++
                return arr
            }
            loop {
                this.SkipWhitespace()
                arr.Push(this.ParseValue())
                this.SkipWhitespace()
                ch := SubStr(this.str, this.pos, 1)
                if ch == "]" {
                    this.pos++
                    return arr
                }
                this.Expect(",")
            }
        }

        ParseString() {
            this.Expect('"')
            result := ""
            loop {
                if this.pos > this.len
                    throw Error("JSON: unterminated string")
                ch := SubStr(this.str, this.pos, 1)
                this.pos++
                if ch == '"'
                    return result
                if ch == "\" {
                    if this.pos > this.len
                        throw Error("JSON: unterminated escape sequence")
                    esc := SubStr(this.str, this.pos, 1)
                    this.pos++
                    switch esc {
                        case '"':  result .= '"'
                        case "\": result .= "\"
                        case "/":  result .= "/"
                        case "b":  result .= Chr(8)
                        case "f":  result .= Chr(12)
                        case "n":  result .= "`n"
                        case "r":  result .= "`r"
                        case "t":  result .= "`t"
                        case "u":
                            hex := SubStr(this.str, this.pos, 4)
                            this.pos += 4
                            result .= Chr(("0x" . hex) + 0)
                        default:
                            throw Error("JSON: invalid escape '\\" . esc . "'")
                    }
                } else {
                    result .= ch
                }
            }
        }

        ParseNumber() {
            start := this.pos
            if SubStr(this.str, this.pos, 1) == "-"
                this.pos++
            while this.pos <= this.len {
                ch := SubStr(this.str, this.pos, 1)
                if Ord(ch) < 48 || Ord(ch) > 57
                    break
                this.pos++
            }
            isFloat := false
            if this.pos <= this.len && SubStr(this.str, this.pos, 1) == "." {
                isFloat := true
                this.pos++
                while this.pos <= this.len {
                    ch := SubStr(this.str, this.pos, 1)
                    if Ord(ch) < 48 || Ord(ch) > 57
                        break
                    this.pos++
                }
            }
            if this.pos <= this.len {
                ch := SubStr(this.str, this.pos, 1)
                if ch == "e" || ch == "E" {
                    isFloat := true
                    this.pos++
                    if this.pos <= this.len {
                        ch2 := SubStr(this.str, this.pos, 1)
                        if ch2 == "+" || ch2 == "-"
                            this.pos++
                    }
                    while this.pos <= this.len {
                        ch := SubStr(this.str, this.pos, 1)
                        if Ord(ch) < 48 || Ord(ch) > 57
                            break
                        this.pos++
                    }
                }
            }
            numStr := SubStr(this.str, start, this.pos - start)
            ; Use arithmetic to convert string→number (Integer/Float reject raw strings)
            return numStr + 0
        }

        ParseBool() {
            if SubStr(this.str, this.pos, 4) == "true" {
                this.pos += 4
                return 1
            }
            if SubStr(this.str, this.pos, 5) == "false" {
                this.pos += 5
                return 0
            }
            throw Error("JSON: expected boolean at pos " . this.pos)
        }

        ParseNull() {
            if SubStr(this.str, this.pos, 4) == "null" {
                this.pos += 4
                return ""
            }
            throw Error("JSON: expected null at pos " . this.pos)
        }

        SkipWhitespace() {
            while this.pos <= this.len {
                ch := SubStr(this.str, this.pos, 1)
                if ch != " " && ch != "`t" && ch != "`n" && ch != "`r"
                    break
                this.pos++
            }
        }

        Expect(ch) {
            got := SubStr(this.str, this.pos, 1)
            if got != ch
                throw Error("JSON: expected '" . ch . "' at pos " . this.pos . ", got '" . got . "'")
            this.pos++
        }
    }
}
