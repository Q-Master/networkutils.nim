# Package
description = "Various networking utils"
version     = "0.6"
license     = "MIT"
author      = "Vladimir Berezenko <qmaster2000@gmail.com>"

# Dependencies
requires "nim >= 1.4.00", "ptr_math"

task test, "tests":
  let tests = @["asyncnetwork", "buffered_socket"]
  for test in tests:
    echo "Running " & test & " test"
    try:
      exec "nim c -r tests/" & test & ".nim"
    except OSError:
      continue
