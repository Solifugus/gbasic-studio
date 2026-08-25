' STU-10 headless driver for credential storage (studio_secrets). Design Q13.
'
' The property this exists to demonstrate is a NEGATIVE one -- that a secret is
' not on disk in the clear -- so the tests read the actual file and look.
'
' args: mode home

function show(lines)
  for each l in lines
    print l
  end for
end function

function file_text(path)
  f{file} = path
  if not exists(f) then
    return ""
  end if
  return read(f)
end function

program main(args)
  load persist
  load crypto
  load studio_secrets

  mode = args[0]
  home = args[1]
  persist.ensure_dir(home)

  ' A fixed key, so the goldens are reproducible. A real one comes from the
  ' environment and Studio never sees it written down.
  key = studio_secrets.key_from_hex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
  secret = "sk-ant-api03-NOTAREALKEY-000000000000000000000000"

  if mode = "roundtrip" then
    print "-- an empty home has an empty store, which is not an error"
    show(studio_secrets.summary(home, key))
    print ""
    r = studio_secrets.put(home, key, "anthropic", secret)
    print "put: ok=" + string(r.ok) + " " + r.why
    r = studio_secrets.put(home, key, "openai", "sk-proj-ALSO-NOT-REAL-1111111111111111")
    print "put: ok=" + string(r.ok)
    print ""
    show(studio_secrets.summary(home, key))
    print ""
    print "-- reading one back"
    g = studio_secrets.get(home, key, "anthropic")
    print "  ok=" + string(g.ok) + " matches: " + string(g.value = secret)
    print ""
    print "-- a name that is not there is reported, not invented"
    g2 = studio_secrets.get(home, key, "cohere")
    print "  ok=" + string(g2.ok) + " — " + g2.why
    print ""
    print "-- dropping one"
    drop_result = studio_secrets.drop(home, key, "openai")
    print "  stored now: " + join(studio_secrets.names(home, key), ", ")
  end if

  if mode = "onhurt" then
    put_result = studio_secrets.put(home, key, "anthropic", secret)
    text = file_text(studio_secrets.store_path(home))
    print "THE POINT OF ALL THIS: the secret is not in the file."
    print ""
    ' The BYTES are not printed: AES-GCM uses a fresh random nonce every time, so
    ' the ciphertext differs on every run and a golden holding any of it would
    ' never match twice. What is stable is that it is hex, and how much.
    print "  the file is " + len(text) + " characters, all of them hex"
    print ""
    print "  contains the secret:        " + string(find(text, secret) != nothing)
    print "  contains 'sk-ant':          " + string(find(text, "sk-ant") != nothing)
    print "  contains the name it is under: " + string(find(text, "anthropic") != nothing)
    print ""
    print "-- and the key is not in the file either, because it is never written"
    print "  contains the key: " + string(find(text, "00112233") != nothing)
    kf{file} = home + "/secrets.key"
    print "  a key file exists: " + string(exists(kf))

    print ""
    print "-- the WRONG key cannot read it, and does not pretend to"
    other = studio_secrets.key_from_hex("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
    bad = studio_secrets.load_all(home, other)
    print "  ok=" + string(bad.ok) + " status=" + bad.status
    print "  (AES-GCM is authenticated, so 'wrong key' and 'tampered' are the"
    print "   same answer — and saying which would be inventing information the"
    print "   cipher deliberately does not give)"

    print ""
    print "-- a locked store is not an empty one"
    locked = studio_secrets.load_all(home, unknown)
    print "  ok=" + string(locked.ok) + " status=" + locked.status
    print "  names(): " + count(studio_secrets.names(home, unknown)) + " (a locked store lists nothing)"
  end if

  if mode = "refusals" then
    print "-- a malformed key is refused rather than padded or hashed into shape"
    for each k in ["", "short", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeZZ", "00112233445566778899aabbccddeeff00112233445566778899aabbccddee"]
      print "  " + quote(k) + " -> usable: " + string(not is_unknown(studio_secrets.key_from_hex(k)))
    end for
    print ""
    print "-- a 64-hex key is usable, in either case"
    print "  lower: " + string(not is_unknown(studio_secrets.key_from_hex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")))
    print "  upper: " + string(not is_unknown(studio_secrets.key_from_hex("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")))
    print ""
    print "-- storing without a key REFUSES. It does not fall back to plaintext:"
    print "   a store that silently degrades is worse than none, because the user"
    print "   believes the first thing they were told."
    r = studio_secrets.put(home, unknown, "anthropic", secret)
    print "  ok=" + string(r.ok) + " — " + r.why
    print "  a file was written: " + string(file_text(studio_secrets.store_path(home)) != "")
    print ""
    print "-- and the state is one word, so no caller has to infer it"
    print "  " + studio_secrets.state()
  end if

  if mode = "redact" then
    put_result = studio_secrets.put(home, key, "anthropic", secret)
    print "a secret can arrive in a log by accident — an error quoting a request,"
    print "a tool argument echoed back. Redaction is the last line, not the first."
    print ""
    msg = "POST /v1/messages failed: header x-api-key=" + secret + " rejected"
    print "  before: " + msg
    print "  after:  " + studio_secrets.redact(msg, home, key)
    print ""
    print "-- a short secret is NOT redacted: it would match everywhere and turn"
    print "   ordinary text into a wall of markers."
    put_result = studio_secrets.put(home, key, "pin", "42")
    print "  " + studio_secrets.redact("the answer is 42, on line 42", home, key)
    print ""
    print "-- and the summary shows names and LENGTHS, never a prefix: the first"
    print "   four characters of an API key identify the provider and the account."
    show(studio_secrets.summary(home, key))
  end if
end program
