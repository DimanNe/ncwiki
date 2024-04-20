#!/usr/bin/env fish

set attempts 0
while true
   timeout 1s docker exec db healthcheck.sh --su-mysql --connect --innodb_initialized
   if test $status -eq 0
      break
   end
   sleep 0.1
   set attempts (math "$attempts + 1")
   if test $attempts -ge 50
      echo "Failed to connect to the database after 50 attempts."
      exit 1
   end
end
