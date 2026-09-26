' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' Is aes_gcm available in this build? It sits behind HAVE_LIBCRYPTO, and a
' Studio built against an interpreter without it must SKIP the secret tiers
' rather than fail them.
program main(args)
  load studio_secrets
  if not studio_secrets.available() then
    exit(1)
  end if
end program
