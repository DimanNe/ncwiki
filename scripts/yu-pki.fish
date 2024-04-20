set -l this_dir (dirname (realpath (status current-filename)))
source $this_dir/util.fish



# 521 is not supported by chrome: https://groups.google.com/a/chromium.org/g/security-dev/c/SlfABuvvQas/m/qOil2X4UBQAJ?pli=1
set YU_PKI_EC_KEY_SIZE   384
set YU_PKI_SLOT          9c
set YU_PKI_RANDOM_ID_LEN 5


function yu-pki-reset-piv
   argparse --ignore-unknown "serial=" -- $argv || return
   if not set -q _flag_serial
      echo -e "You have to provide "$BWhite"--serial"$Color_Off". Choose one from:"
      RunVerbosely ykman list
      return
   end
   RunVerbosely ykman --device $_flag_serial piv reset --force || return
   RunVerbosely ykman --device $_flag_serial piv access set-retries     \
      --force                                                           \
      --management-key 010203040506070801020304050607080102030405060708 \
      --pin 123456                                                      \
      5 5

   echo "Set new PIN:"
   RunVerbosely ykman --device $_flag_serial piv access change-pin --pin 123456
   echo "Set new PUK:"
   RunVerbosely ykman --device $_flag_serial piv access change-puk --puk 12345678
end



function yu-pki-info
   argparse --ignore-unknown "serial=" -- $argv || return
   if not set -q _flag_serial
      echo -e "You have to provide "$BWhite"--serial"$Color_Off". Choose one from:"
      RunVerbosely ykman list
      return
   end
   RunVerbosely ykman --device $_flag_serial piv info
   echo -e "\n\n"$BrightGray"For the following commands, you might need to "$BWhite"apt install gnutls-bin ykcs11"$Color_Off"\n"
   RunVerbosely pkcs11-tool --module /usr/lib/x86_64-linux-gnu/libykcs11.so -O
   echo
   RunVerbosely p11tool --provider /usr/lib/x86_64-linux-gnu/libykcs11.so --list-privkeys --login
end



# ============================================================================================================



function impl_gen_random  --argument-names len
   tr -dc 'a-z' </dev/random | head -c $len
   echo
end



function yu-pki-generate-keypair-and-cert-ca
   argparse --ignore-unknown "serial=" -- $argv || return
   if not set -q _flag_serial
      echo -e "You have to provide "$BWhite"--serial"$Color_Off". Choose one from:"
      RunVerbosely ykman list
      return
   end
   set -l workdir  (mktemp -d  /dev/shm/yu-pki-(date +%s)-XXX) # && cd $workdir && mkdir -p $workdir/rsa

   echo -e "\n"$Yellow"Generating CA keypair..."$Color_Off
   RunVerbosely ykman --device $_flag_serial piv keys         generate \
      --algorithm ECCP$YU_PKI_EC_KEY_SIZE --pin-policy ALWAYS --touch-policy ALWAYS $YU_PKI_SLOT /dev/null || return

   # We could just provide the path for the public key (instead of /dev/null) for the command above, but it
   # would be "less" idempotent as it would mean that we HAVE to generate private key each time we want to
   # get public key and generate self-signed certificate. But user might already have a keypair, so, let's
   # try to use what we already have:
   echo -e "\n"$Yellow"Obtaining public key..."$Color_Off
   RunVerbosely ykman --device $_flag_serial piv keys export --verify --format PEM $YU_PKI_SLOT $workdir/CA-pub.pem || return


   set -l key            02
   set -l subject        CA-(impl_gen_random $YU_PKI_RANDOM_ID_LEN)

   echo -e "\n"$Yellow"Generating temporary self-signed certificate in Yubikey..."$Color_Off
   RunVerbosely ykman --device $_flag_serial piv certificates generate \
      --subject        $subject                                        \
      --valid-days     36500                                           \
      --hash-algorithm SHA$YU_PKI_EC_KEY_SIZE $YU_PKI_SLOT             \
      $workdir/CA-pub.pem
   rm $workdir/CA-pub.pem


   set -l openssl_config (echo "
[ req ]
prompt = no
distinguished_name = req_distinguished_name
req_extensions = some_section_name

[ req_distinguished_name ]
CN = $subject

[some_section_name]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
   " | string split0)

   echo -e "\n"$Yellow"Creating self-signed CA certificate with the following config:"$Color_Off
   echo -e "$openssl_config"

   RunVerbosely openssl req                    \
      -new                                     \
      -x509                                    \
      -engine pkcs11                           \
      -keyform engine                          \
      -key $key                                \
      -sha$YU_PKI_EC_KEY_SIZE                  \
      -days 36500                              \
      -config (echo -e $openssl_config | psub) \
      -extensions some_section_name            \
      -out $workdir/CA-cert.pem                || return

   echo "Generated self-signed certificate:"
   RunVerbosely openssl x509 -text -noout -in $workdir/CA-cert.pem

   echo -e "\n"$Yellow"Importing the certificate to Yubikey..."$Color_Off
   RunVerbosely ykman --device $_flag_serial piv certificates import --verify $YU_PKI_SLOT $workdir/CA-cert.pem || return
   rm $workdir/CA-cert.pem
   rm -rf $workdir

   echo -e "\n"$Yellow"Done: Generated keypair and self-signed CA certificate"$Color_Off
   echo "You can extract CA via: ykman --device $_flag_serial piv certificates export $YU_PKI_SLOT -"
   RunVerbosely ykman --device $_flag_serial piv info
end




# ============================================================================================================



# We have to use OpenSSL config where we specify capabilities of the key as well as extension (values)
# https://www.openssl.org/docs/man1.0.2/man5/x509v3_config.html
# Example of the config:
# [some_section_name]
# basicConstraints=critical,CA:FALSE
# keyUsage=critical, digitalSignature, nonRepudiation, keyEncipherment, keyAgreement
# extendedKeyUsage=critical, serverAuth
# subjectAltName=IP:127.0.0.1,DNS:asdf.qwer
function yu-pki-sign-csr
   argparse --ignore-unknown "openssl-config=" "csr=" "ca=" "out-cert=" -- $argv || return
   if not set -q _flag_openssl_config
      echo "Specify openssl config"
      return
   end
   if not set -q _flag_csr
      echo "Specify csr"
      return
   end
   if not set -q _flag_ca
      echo "Specify ca"
      return
   end
   if not set -q _flag_out_cert
      echo "Specify out_cert"
      return
   end

   # CAkey might be: 'pkcs11:manufacturer=piv_II;id=%02', Or just 02 See the list of labels in yu-pki-info
   set -l CAkey       02
   set -l pass        (tr -dc 'A-Za-z0-9' </dev/random | head -c 20)

   echo -e "\n"$Yellow"Signing CSR with private key in slot $CAkey and the config:"$Color_Off
   cat $_flag_openssl_config
   RunVerbosely openssl x509            \
      -req                              \
      -extensions some_section_name     \
      -extfile    $_flag_openssl_config \
      -days       36500                 \
      -sha$YU_PKI_EC_KEY_SIZE           \
      -engine     pkcs11                \
      -in         $_flag_csr            \
      -CAkeyform  engine                \
      -CAkey      $CAkey                \
      -CA         $_flag_ca             \
      -out        $_flag_out_cert

   echo -e "\n"$Yellow"Successfully got certificate:"$Color_Off
   RunVerbosely openssl x509 -in $_flag_out_cert -text -noout
end




# We have to use OpenSSL config where we specify capabilities of the key as well as extension (values)
# https://www.openssl.org/docs/man1.0.2/man5/x509v3_config.html
# Example of the config:
# [some_section_name]
# basicConstraints=critical,CA:FALSE
# keyUsage=critical, digitalSignature, nonRepudiation, keyEncipherment, keyAgreement
# extendedKeyUsage=critical, serverAuth
# subjectAltName=IP:127.0.0.1,DNS:asdf.qwer
function yu-pki-generate-keypair-and-cert-common
   argparse --ignore-unknown "serial=" "openssl-config=" "hosts=" "for_whom=" "dump-private-key" -- $argv || return
   if not set -q _flag_serial
      echo -e "You have to provide "$BWhite"--serial"$Color_Off". Choose one from:"
      RunVerbosely ykman list
      return
   end
   if not set -q _flag_for_whom
      echo "Specify name of entity for whom we generate"
      return
   end
   if not set -q _flag_openssl_config
      echo "Specify openssl config"
      return
   end

   echo -e "\n"$Yellow"Generating $_flag_for_whom keypair & CSR...$Color_Off"
   if not command -v cfssl > /dev/null
      echo "cfssl does not exist. Install it first:"
      echo "sudo apt install golang-cfssl"
      return
   end

   set -l csr_key (cfssl genkey (echo "{
    \"hosts\": [$_flag_hosts],
    \"key\": { \"algo\": \"ecdsa\", \"size\": $YU_PKI_EC_KEY_SIZE },
    \"names\": [ { \"O\":  \"$_flag_for_whom-"(impl_gen_random $YU_PKI_RANDOM_ID_LEN)"\", \"CN\": \"$_flag_for_whom-"(impl_gen_random $YU_PKI_RANDOM_ID_LEN)"\" } ]
}" | psub))

   set -l csr         (echo $csr_key | jq -r '.csr' | string split0)
   set -l private_key (echo $csr_key | jq -r '.key' | string split0)
   echo "Generated CSR:"
   RunVerbosely openssl req -in (echo -e $csr | psub) -noout -text

   set -l workdir  (mktemp -d  /dev/shm/yu-pki-(date +%s)-XXX) # && cd $workdir && mkdir -p $workdir/rsa
   echo -e "\n"$Yellow"Extracing CA certificate from the token..."$Color_Off
   RunVerbosely ykman --device $_flag_serial piv certificates export $YU_PKI_SLOT $workdir/CA.crt.pem || return
   RunVerbosely openssl x509 -text -noout -in $workdir/CA.crt.pem

   # CAkey might be: 'pkcs11:manufacturer=piv_II;id=%02', Or just 02 See the list of labels in yu-pki-info
   set -l CAkey       02
   set -l pass        (tr -dc 'A-Za-z0-9' </dev/random | head -c 20)

   RunVerbosely yu-pki-sign-csr --openssl-config $_flag_openssl_config -csr (echo -e $csr | psub) -ca $workdir/CA.crt.pem --out-cert $workdir/$_flag_for_whom-cert.pem


   echo -e "\n"$Yellow"Preparing encrypted p12 bundle with results..."$Color_Off

   set -l bundle_pass (impl_gen_random 50)
   RunVerbosely openssl pkcs12 -export              \
      -in      $workdir/$_flag_for_whom-cert.pem    \
      -inkey   (echo -e $private_key | psub)        \
      -out     $workdir/$_flag_for_whom-bundle.p12  \
      -passout pass:$bundle_pass

   RunVerbosely openssl pkcs12 -export -legacy          \
      -in    $workdir/$_flag_for_whom-cert.pem          \
      -inkey (echo -e $private_key | psub)              \
      -out   $workdir/$_flag_for_whom-legacy-bundle.p12 \
      -passout pass:$bundle_pass

   if set -q _flag_dump_private_key
      echo -e $private_key > $workdir/$_flag_for_whom-key.pem
   end


   echo -e "\n"$Yellow"Install the p12 bundle and CA$Color_Off:"
   echo -e "   * $BYellow$workdir/$_flag_for_whom-bundle.p12$Color_Off or $BYellow$workdir/$_flag_for_whom-legacy-bundle.p12$Color_Off"
   echo -e "     Use this to pass password:"
   echo -e "     "$Gray"echo $bundle_pass | qrencode -o - | feh --force-aliasing -ZF -"$Color_Off
   echo -e "   * $BYellow$workdir/CA.crt.pem$Color_Off"
   if set -q _flag_dump_private_key
      echo -e "   * $BYellow""cp $workdir/$_flag_for_whom-key.pem$Color_Off"
   end
   echo
   read -P "Press any key to remove the private key..."
   RunVerbosely rm -rf $workdir
end




function yu-pki-generate-keypair-and-cert-server
   # Example of usage:
   # yu-pki-generate-keypair-and-cert-server --serial 1111111 --host asdf.qwer --host zxcv.qwer --ip 127.0.0.1
   argparse --ignore-unknown "serial=" "host=+" "ip=+" "dump-private-key" -- $argv || return
   if not set -q _flag_serial
      echo -e "You have to provide "$BWhite"--serial"$Color_Off". Choose one from:"
      RunVerbosely ykman list
      return
   end
   if not set -q _flag_host; and not set -q _flag_ip
      echo -e "You have to provide either "$BWhite"--host"$Color_Off" and/or "$BWhite"--ip"$Color_Off" for server keypair/certificate."
      return
   end
   set hosts
   set sans
   for host in $_flag_host
      set hosts $hosts "\"$host\""
      set sans  $sans "DNS:$host"
   end
   for ip in $_flag_ip
      set hosts $hosts "\"$ip\""
      set sans  $sans "IP:$ip"
   end
   set hosts (string join ", " $hosts)
   set sans  (string join "," $sans)

   set openssl_config (echo "
[some_section_name]
basicConstraints=critical,CA:FALSE
keyUsage=critical, digitalSignature, nonRepudiation, keyEncipherment, keyAgreement
extendedKeyUsage=critical, serverAuth
subjectAltName=$sans
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
" | string split0)
   yu-pki-generate-keypair-and-cert-common --serial $_flag_serial --openssl-config (echo -e $openssl_config | psub) --hosts "$hosts" --for_whom server $_flag_dump_private_key
end




function yu-pki-generate-keypair-and-cert-client
   argparse --ignore-unknown "serial=" "dump-private-key" -- $argv || return
   if not set -q _flag_serial
      echo -e "You have to provide "$BWhite"--serial"$Color_Off". Choose one from:"
      RunVerbosely ykman list
      return
   end

   set openssl_config (echo "
[some_section_name]
basicConstraints=critical,CA:FALSE
keyUsage=critical, digitalSignature, nonRepudiation, keyEncipherment, keyAgreement
extendedKeyUsage=critical, clientAuth
" | string split0)
   yu-pki-generate-keypair-and-cert-common --serial $_flag_serial --openssl-config (echo -e $openssl_config | psub) --hosts "" --for_whom client $_flag_dump_private_key
end
