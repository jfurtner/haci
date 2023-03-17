#!/bin/bash

### Please consult README.md before running this.

###
### config
###

# linux binary dependencies are listed here (except for echo - that is assumed)."
BINS="grep sed curl openssl find cat awk cp ln pip python find mv"

# certificates directory (can be /opt/etc/ssl/certs on *WRT)
CDS="/etc/ssl/certs"

# ca-certificates file
CAS="$CDS/ca-certificates.crt"

# config file
CONFIG="haci.conf"

###
### functions
###

# comm functions
function _SAY { [ -z $debug ] || {
    echo -ne "  `date`:$1\n" >> "$LOG_OUT_FILE"
    #echo -ne "$1\n" 
  }
  return 0; 
}
function _ERR { 
  [ -z $debug ] || echo -e "!!! Error: $1" >> "$LOG_OUT_FILE"
  echo "!!! Error: $1"
  exit 1; 
}
function _WRN {
  [ -z $debug ] || echo -e "??? $1" >> "$LOG_OUT_FILE"
  echo "??? $1"
  return 0
}

# find functions
function FIND_BIN {
  for loc in /bin /usr/bin /usr/local/bin /sbin /usr/sbin /opt/bin /usr/lib; do
      if [ -d "$loc" ]; then if [ -f "$loc/$1" ]; then
         eval "$1"="$loc/$1"; return; fi; fi
  done

  # solve https://github.com/miklosbagi/haci/issues/4 (:beer: -> @mateuszdrab)
  if [ $1 == "openssl" ]; then apk add openssl; return 0; fi

  # fail in case there is no sign of that binary in all those directories...
  return 1
}

# validate internal ssl test site
function CHECK_SSL_INT {
  _SAY "Test $test_site (full SSL)"
  $curl -m 2 -IX GET "$test_site" >> $LOG_OUT_FILE 2>&1 && return 0 || return 1; }
function CHECK_SSL_INT_INSECURE { 
  _SAY "Test $test_site (insecurely)"
  $curl -m 2 -k "$test_site" >> $LOG_OUT_FILE 2>&1 && return 0 || return 1; }
function CHECK_SSL_INT_PY { $python -c "exec('import requests\ntry:\n\tr=requests.get(\"$test_site\")\nexcept:\n\texit(1)')" 2>&1 >> $LOG_OUT_FILE || return 1; }

# create backup of certificates file
function CERT_BACKUP {
  # create backup
  _SAY "Creating backup for $1"
  # create a backup of the ca-certificates file in case it doesn't exist yet.
  [ ! -f "${0%/*}/${1##*/}.backup" ] && { cp "$1" "${0%/*}/${1##*/}.backup" && _SAY "Created backup for $1 as ${0%/*}/${1##*/}.backup" || _WRN "Failed creating backup for $1"; }
}

# load up all certificates from file
function CERT_LOADUP {
  _SAY "Loading up $1 data, please be patient..."
  # load up all serial/subject from ca-certificates (used to check if cert is already added)
  all_certs_data=`$grep -v "^#\|^$" "$1" | $awk -v cmd="$openssl x509 -noout -serial -subject" "/BEGIN/{close(cmd)};{print | cmd}"` || _ERR "Error loading ca-certificates serial & subject data."
  [ -z "$all_certs_data" ] && _ERR "ca-certificates comparison data is empty."
  _SAY "Loaded up all ca-certificates data for comparison."
}

# roll & inject if needed
function CERT_CA_INJECT {
  # iterate through the certs to be added
  for c in $certs; do
    # validate certificate is pem with openssl
    v=`$openssl x509 -in $c -text -noout >/dev/null 2>&1` || { _WRN "Certificate $c is not a valid pem formatted certificate, skipping."; continue; }
    _SAY "Certificate $c looks valid."

    # load up certificate data for commparison
    this_cert_data=`$grep -v "^#\|^$" "$1" | $awk -v cmd="$openssl x509 -noout -serial -subject" "/BEGIN/{close(cmd)};{print | cmd}" < "$c"` || _ERR "Error $c serial & subject data."

    # check if this cert added already, and do not proceed if so.
    inject=""
    t=`echo "$all_certs_data" |$grep -q "$this_cert_data"` && { _SAY "- Certificate is already added, skipping." && inject=1; }

    # load up and push cert
    [ -z $inject ] && {
      this_cert=`$cat $c` || { _WRN "Error reading up $c, skipping."; continue; }
      _SAY "- Pushing $c into $1..."
      echo -ne "$this_cert\n\n" >> "$1" || _WRN "Error pushing $c to ${1##*/}"
      _SAY "- Added $c to ${1##*/}"
    }
    done
}

###
### exec
###

# find all the bins required.
for bin in $BINS; do FIND_BIN "$bin" || _ERR "Cannot find $bin in PATH or at common locations."; done

# switch on debug if it's been defined.
d=`echo "$1" |$grep -i -q "debug"` && debug="1"
[ -z $debug ] && export LOG_OUT_FILE=/dev/null || export LOG_OUT_FILE=/share/haci.txt 
_SAY "\b\bRunning with debug"

# load config
[ -f ${0%/*}/$CONFIG ] && { source "${0%/*}/$CONFIG" || _ERR "Failed loading config: $CONFIG."; } || _ERR "Config file $CONFIG does not exist or no access."
_SAY "Config loaded"

# validate test site 1,2
[ -z "$test_site" ] && _ERR "Test site (test_site) is not defined in CONFIG $config"
a=`echo "$test_site" | $grep -q "^https://"` || _ERR "Test site \"$test_site\" is not https://"
_SAY "Test site ($test_site) passed basic validation"

# check if site is up at all
CHECK_SSL_INT_INSECURE || _ERR "The test_side provided "$test_site" in CONFIG doesn't seem to return useful data. Is it up? (try curl -sk $test_site)"
_SAY "Test site returns useful data when hit insecurely"

# check if we can hit test site securely (in case there's no point running any further)
int_ssl_status=""; int_ssl_py_status=""
CHECK_SSL_INT && { _SAY "Linux SSL is passing, not injecting anything."; } || { _SAY "Linux SSL is failing with $test_site, injection required."; int_ssl_status="0"; }
[ ! -z "$certifi" ] && {
  CHECK_SSL_INT_PY && { _SAY "Py Certifi is passing, not injecting anything."; } || { _SAY "Python Certifi SSL is failing with $test_site, injection required."; int_ssl_py_status="0"; }
}

# exit if we have nothing to do
[ -z $int_ssl_status ] && [ -z $int_ssl_py_status ] && exit 0

# check that the certs we are having are actually certs
[ -d "${0%/*}/certs" ] || _ERR "${0%/*}/certs directory is missing. Please create that and put your .pem, .crt or .cer certificates in it"
_SAY "The ${0%/*}/certs directory exists"

# find all the certs to be added
certs=`$find "${0%/*}/certs"/ -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.cer" \)` || _ERR "Find throws error for ${0%/*}/certs"
[ -z "$certs" ] && _ERR "No certificates were found in ${0%/*}/certs, please place your Root CA and any intermediate CAs in that directory in PEM format."
_SAY "Found certs: \n$certs" |$sed 's#^[\./]./\?#  - #'

DATE=`date +%Y%m%d-%H%M%S`


# add linux core certs if needed
[ ! -z $int_ssl_status ] && {
  _SAY "Injecting Certs to Linux..."

  # check if ca-certificates file actually exists
  [ -f "$CAS" ] || _ERR "Whoops, we need $CAS to exist. Looks like there's no certs at all on this system."
  _SAY "Great, $CAS is in place."
  # create backup
  CERT_BACKUP "$CAS"
  # load up certs
  CERT_LOADUP "$CAS"
  
  # this doesn't appear to work, just manually combine all certs into one big file
  # inject to CA file if need to
  #CERT_CA_INJECT "$CAS"

  # copy cert files over to ca-dir
  for c in $certs; do
    # copy cert to certs dir ${a##*/}
    [ ! -f "$CDS/${c##*/}" ] && { cp "$c" "$CDS/" || _WRN "Failed to copy ${c##*/} to /etc/ssl/certs"; } || _SAY "- $CDS/${c##*/} already exists, no copy."
    _SAY "- $CDS/$c is in place"

    # Create pem hash
    pem_hash=`$openssl x509 -hash -noout -in "$c"` || { _WRN "Failed creating pem hash for ${c##*/}, WILL NOT LINK."; continue; }
    _SAY "- PEM hash is: $pem_hash"
    # symlink hash to certs dir (note low risk with .0 here)
    [ -f "$CDS/${c##*/}" ] && [ ! -L "$CDS/${pem_hash}.0" ] && { $ln -s "${c##*/}" "$CDS/${pem_hash}.0" || _WRN "Error creating symlink $pem_hash.0 for $CDS/${c##*/}"; } || _SAY "- ${c##*/} is already linked, skipping."
    _SAY "- $CDS/${c##*/} is linked to $CDS/${pem_hash}.0."
  done

  _SAY "Creating new ca-certificates.crt"
  find "$CDS" -name '*.pem' -exec cat {} \; > "$CDS/ca-certificates.crt.new.$DATE"
  _SAY "real backup of $CAS"
  cp "$CAS" "$CAS.old.$DATE"
  _SAY "now replace $CAS"
  mv "$CAS.new.$DATE" "$CAS"

  _SAY "Retest Linux SSL"
  # check SSL trust again, fingers crossed all worked fine.
  CHECK_SSL_INT && _SAY "Test site says Linux SSL handshake is passing now, success." || { 
    _ERR "Linux SSL Tests are still failing, this should not happen.\n   Please raise an issue on github.\n"
    exit 1
  }
}

[ ! -z $int_ssl_py_status ] && {
  _SAY "Injecting Certs to Python Certifi..."
  # dig out CA file from certifi installation (may change for future py versions)
  _SAY "Digging certifi installation (may take a while)..."
  py_ca_loc=`$pip show -f certifi |grep "^Location: \|cacert.pem" |tr "\n" "/" |sed 's#Location: ##;s#  ##;s#/$##'`
  [ ! -f $py_ca_loc ] && { _ERR "File $py_ca_loc does not exist, cannot proceed."; }
  _SAY "Certifi CA file to patch is $py_ca_loc."
  # create backup
  CERT_BACKUP "$py_ca_loc"
  # load up certs
  CERT_LOADUP "$py_ca_loc"
  # inject to CA file if need to
  #CERT_CA_INJECT "$py_ca_loc"


  _SAY "Backup cacert.pem"
  cp "$py_ca_loc" "$py_ca_loc.old.$DATE"
  
  _SAY "Copy ca-certificates to python cacert.pem"
  cp "$CDS/ca-certificates.crt" "$py_ca_loc"

  CHECK_SSL_INT_PY && _SAY "Test site says Python Certifi SSL handshake is passing now, success." || { 
    _ERR "Python Certifi SSL Tests are still failing, this should not happen.\n   Please raise an issue on github.\n"
    exit 1
  }
}

_SAY "Completed"
exit 0
# eof
