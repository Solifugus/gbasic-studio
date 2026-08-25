' studio_secrets — STU-10 credential storage (headless). Design Q13.
'
' The requirement (§16) is short: API keys are NEVER stored as ordinary plaintext
' config. What follows is what that can honestly mean on this platform today, and
' what it cannot.
'
' ---------------------------------------------------------------------------
' WHAT THIS PROTECTS AGAINST, AND WHAT IT DOES NOT.
'
' The design names the OS keyring as the target and this as the near-term
' fallback. gBASIC has no keyring binding, so this is the fallback, and it is
' worth being exact about what it buys:
'
'   PROTECTED: the secret is not in a config file, a dotfile, a project
'   directory, a backup, a screenshot of a settings pane, or a repository
'   somebody commits by accident. Those are how API keys actually leak, and the
'   store is ciphertext against all of them.
'
'   NOT PROTECTED: an attacker who can read the user''s environment while Studio
'   runs -- another process of the same user, a core dump, a debugger. The key is
'   in memory while Studio holds it, and nothing here can change that.
'
' THE KEY IS NEVER WRITTEN TO DISK. It comes from the environment
' (GBASIC_STUDIO_SECRET_KEY, 64 hex characters), so the user can source it from a
' password manager. Studio does not create it, does not store it, and does not
' offer to remember it. A key file beside its own ciphertext protects against
' almost nothing, and writing one would let this claim to be encrypted while
' being, in practice, obfuscated.
'
' NO PASSPHRASE DERIVATION, deliberately. A passphrase would be friendlier and
' the platform has no PBKDF/scrypt/argon2 -- only sha256. Hashing a passphrase
' once is brute-forceable at enormous speed, so offering it would be offering
' something that looks like a password and is not. `new_key()` mints a real one
' instead.
'
' WITHOUT CRYPTO, THE STORE REFUSES. `sha256`/`aes_gcm` sit behind
' HAVE_LIBCRYPTO and an interpreter can be built without them. In that build this
' does not fall back to plaintext -- it declines to store anything, and says why.
' A secret store that silently degrades to plaintext is worse than no secret
' store, because the user believes the first thing they were told.
library studio_secrets


    load crypto
    load persist

    function schema_version()
        return 1
    end function

    function key_var()
        return "GBASIC_STUDIO_SECRET_KEY"
    end function

    function store_path(home)
        return home + "/secrets.enc"
    end function

    ' 32 bytes, as 64 hex characters.
    function key_bytes()
        return 32
    end function

    ' ---- the key ------------------------------------------------------------

    ' Mint a key for the user to put in their password manager. Studio prints it
    ' once and never stores it; if it is lost the store cannot be read, which is
    ' the correct behaviour for something whose whole purpose is that only the
    ' holder can read it.
    function new_key()
        return crypto.random_hex(studio_secrets.key_bytes())
    end function

    ' The key as bytes, or `unknown` when there is not a usable one. A wrong-length
    ' or non-hex value is refused rather than padded or hashed into shape: a key
    ' that is quietly "fixed" is a key the user thinks they know and does not.
    function key_from_env()
        v = env(studio_secrets.key_var())
        if not is_string(v) then
            return unknown
        end if
        return studio_secrets.key_from_hex(v)
    end function

    function key_from_hex(v)
        if not is_string(v) then
            return unknown
        end if
        t = trim(v)
        if len(t) != studio_secrets.key_bytes() * 2 then
            return unknown
        end if
        if not studio_secrets._is_hex(t) then
            return unknown
        end if
        return hex_decode(t)
    end function

    function _is_hex(t)
        i = 0
        while i < len(t)
            c = lower(mid(t, i, 1))
            ok = false
            if c >= "0" then
                if c <= "9" then
                    ok = true
                end if
            end if
            if c >= "a" then
                if c <= "f" then
                    ok = true
                end if
            end if
            if not ok then
                return false
            end if
            i = i + 1
        end while
        return true
    end function

    ' ---- is this build able to keep a secret at all? ------------------------

    ' Probed, not assumed. `aes_gcm_encrypt` is behind HAVE_LIBCRYPTO, and asking
    ' the question by trying it is the only way to get a true answer on an
    ' interpreter that was built without it.
    function available()
        k = studio_secrets._probe_key()
        blob = crypto.encrypt(k, "probe")
        if is_unknown(blob) then
            return false
        end if
        return crypto.decrypt(k, blob) = "probe"
    end function

    function _probe_key()
        return hex_decode("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
    end function

    ' What state the store is in, as one word, so a caller never has to infer it:
    '   ready       there is a key and crypto works
    '   locked      crypto works but no usable key is in the environment
    '   unusable    this interpreter cannot encrypt
    function state()
        return studio_secrets.state_for(studio_secrets.key_from_env())
    end function

    ' The state given a PARTICULAR key, rather than whatever is in the
    ' environment. The two are the same for the running window and different for
    ' every test and every caller holding a key of its own — and reporting the
    ' environment's answer while using a caller's key is how a summary comes to
    ' say "locked" over a list of secrets it just read.
    function state_for(key)
        if not studio_secrets.available() then
            return "unusable"
        end if
        if is_unknown(key) then
            return "locked"
        end if
        return "ready"
    end function

    function state_line()
        return studio_secrets.state_line_for(studio_secrets.key_from_env())
    end function

    function state_line_for(key)
        s = studio_secrets.state_for(key)
        if s = "ready" then
            return "secrets: ready"
        end if
        if s = "locked" then
            return "secrets: locked — set " + studio_secrets.key_var() + " (64 hex chars) to unlock"
        end if
        return "secrets: unusable — this gBASIC was built without libcrypto, so nothing will be stored"
    end function

    ' ---- reading and writing ------------------------------------------------

    ' The whole store, decrypted, as a record of name -> value. An empty store, a
    ' missing file and a file this key cannot open are three different answers,
    ' and the third one especially must not read as "you have no secrets".
    function load_all(home, key)
        path = studio_secrets.store_path(home)
        f{file} = path
        if not exists(f) then
            return { ok: true, status: "empty", values: {} }
        end if
        if is_unknown(key) then
            return { ok: false, status: "locked", values: {} }
        end if
        blob = hex_decode(trim(read(f)))
        if is_unknown(blob) then
            return { ok: false, status: "corrupt", values: {} }
        end if
        plain = crypto.decrypt(key, blob)
        if is_unknown(plain) then
            ' AES-GCM is authenticated, so this is either the wrong key or a
            ' tampered file, and there is no way to tell which. Saying "wrong key
            ' or damaged" is the whole truth; guessing at one would be inventing
            ' information the cipher deliberately does not give.
            return { ok: false, status: "unreadable", values: {} }
        end if
        r = try_decode(plain)
        if not r.ok then
            return { ok: false, status: "corrupt", values: {} }
        end if
        if not is_record(r.value) then
            return { ok: false, status: "corrupt", values: {} }
        end if
        return { ok: true, status: "ok", values: r.value }
    end function

    function save_all(home, key, values)
        if not studio_secrets.available() then
            return { ok: false, why: "this gBASIC cannot encrypt; nothing was stored" }
        end if
        if is_unknown(key) then
            return { ok: false, why: "no key: set " + studio_secrets.key_var() + " to a 64-character hex key" }
        end if
        blob = crypto.encrypt(key, encode(values))
        if is_unknown(blob) then
            return { ok: false, why: "encryption failed; nothing was stored" }
        end if
        persist.ensure_dir(home)
        path = studio_secrets.store_path(home)
        tmp{file} = path + ".tmp"
        ' Written as hex rather than raw bytes: the store travels through backups
        ' and editors that mangle binary, and a corrupted secret store is
        ' indistinguishable from a wrong key.
        write(tmp, hex_encode(blob) + "\n")
        atomic_replace(path + ".tmp", path)
        return { ok: true, why: "" }
    end function

    function put(home, key, name, value)
        cur = studio_secrets.load_all(home, key)
        if not cur.ok then
            return { ok: false, why: "the store is " + cur.status + "; refusing to overwrite it" }
        end if
        values = cur.values
        values[name] = value
        return studio_secrets.save_all(home, key, values)
    end function

    function get(home, key, name)
        cur = studio_secrets.load_all(home, key)
        if not cur.ok then
            return { ok: false, why: "the store is " + cur.status, value: "" }
        end if
        v = cur.values[name]
        if v = unknown then
            return { ok: false, why: "no secret named " + quote(name), value: "" }
        end if
        return { ok: true, why: "", value: v }
    end function

    ' Named `drop` rather than `remove`, which is a builtin.
    function drop(home, key, name)
        cur = studio_secrets.load_all(home, key)
        if not cur.ok then
            return { ok: false, why: "the store is " + cur.status }
        end if
        values = {}
        for each k in keys(cur.values)
            if k != name then
                values[k] = cur.values[k]
            end if
        end for
        return studio_secrets.save_all(home, key, values)
    end function

    ' The NAMES only. This is what a settings pane and an agent may see: which
    ' credentials exist, never what they are.
    function names(home, key)
        cur = studio_secrets.load_all(home, key)
        if not cur.ok then
            return []
        end if
        return sort(keys(cur.values))
    end function

    ' ---- keeping secrets out of everything else -----------------------------

    ' Replace every stored secret found in `text` with a marker.
    '
    ' This exists because the history log, the status line and the agent's own
    ' transcript are all places a secret can arrive by accident -- an error
    ' message quoting a request, a tool argument echoed back. Redaction at the
    ' point of display is the last line; it is not a substitute for not putting
    ' one there.
    '
    ' Short values are NOT redacted. A one- or two-character secret would match
    ' everywhere and turn ordinary text into a wall of markers, which is its own
    ' kind of unreadable.
    function redact(text, home, key)
        if not is_string(text) then
            return text
        end if
        cur = studio_secrets.load_all(home, key)
        if not cur.ok then
            return text
        end if
        out = text
        for each k in keys(cur.values)
            v = cur.values[k]
            if is_string(v) then
                if len(v) >= studio_secrets.redact_min() then
                    out = replace(out, v, "<" + k + " redacted>")
                end if
            end if
        end for
        return out
    end function

    function redact_min()
        return 8
    end function

    function summary(home, key)
        out = []
        out = append(out, studio_secrets.state_line_for(key))
        cur = studio_secrets.load_all(home, key)
        if not cur.ok then
            out = append(out, "  store: " + cur.status)
            return out
        end if
        nm = sort(keys(cur.values))
        out = append(out, "  stored: " + count(nm))
        for each n in nm
            ' The NAME and the LENGTH. Never a prefix: the first four characters
            ' of an API key identify the provider and the account to anyone who
            ' has seen one before.
            out = append(out, "    " + n + " (" + len(cur.values[n]) + " chars)")
        end for
        return out
    end function

end library
