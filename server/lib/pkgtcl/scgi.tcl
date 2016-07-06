#
# This file provides two packages to build a SCGI-based application
#
# It is in fact divided into 2 different packages:
# - for the server: this package contains only one function to
#	start the multi-threaded SCGI server
# - for the app: this package is implicitely loaded into each thread
#	started by the server (see thrscript)
#

package require Tcl 8.6
package require Thread 2.7

package provide scgi 0.1

namespace eval ::scgi:: {
    namespace export start

    ###########################################################################
    # Server connection and thread pool management
    ###########################################################################

    # thread pool id
    variable tpid

    # server configuration
    variable serconf
    array set serconf {
	-minworkers 2
	-maxworkers 4
	-idletime 30
	-myaddr 0.0.0.0
	-myport 8080
	-debug 1
    }


    #
    # Start a multi-threaded server to handle SCGI requests from the
    # HTTP proxy
    #
    # Usage:
    #	::scgi::start [options] init-script handle-function
    #	with standard options:
    #		-minworkers: minimum number of threads in thread pool
    #		-maxworkers: maximum number of threads in thread pool
    #		-idletime: idle-time for worker threads
    #		-myaddr: address to listen to connections
    #		-myport: port number to listen to connections
    #		-debug: get verbose error message
    #
    #	and arguments:
    #	- init-script: script to call in each worker thread. This script
    #		is called after creating the client scgi package. Since
    #		each thread is created with a default Tcl interpreter
    #		(thus containing only the initial set of Tcl commands),
    #		the init-script should source a file containing the
    #		SCGI application itself.
    #	- handle-function: this is the name of a function inside the
    #		the SCGI application (thus in a worker thread) to
    #		handle a SCGI request from the HTTP proxy. This function
    #		is called with the following arguments:
    #
    #		XXXXXXXXXXXXXXXXX
    #

    proc start args {
	variable tpid
	variable serconf

	#
	# Get default parameters
	#

	array set p [array get serconf]

	#
	# Argument analysis
	#

	while {[llength $args] > 0} {
	    set a [lindex $args 0]
	    switch -glob -- $a {
		-- {
		    set args [lreplace $args 0 0]
		    break
		}
		-* {
		    if {[info exists p($a)]} then {
			set p($a) [lindex $args 1]
			set args [lreplace $args 0 1]
		    } else {
			error "invalid option '$a'. Should be 'server [array get serconf]'"
		    }
		}
		* {
		    break
		}
	    }
	}

	if {[llength $args] != 2} then {
	    error "invalid args: should be init-script handle-request"
	}

	lassign $args initscript handlereq

	variable thrscript

	set tpid [tpool::create \
			-minworkers $p(-minworkers) \
			-maxworkers $p(-maxworkers) \
			-idletime $p(-idletime) \
			-initcmd "$thrscript ;
				set ::scgi::handlefn $handlereq ;
				set ::scgi::debug $p(-debug) ;
				$initscript" \
		    ]

	socket \
	    -server [namespace code server-connect-hack] \
	    -myaddr $p(-myaddr) \
	    $p(-myport)

	vwait forever
    }

    proc server-connect-hack {sock host port} {
	after 0 [namespace code [list server-connect $sock $host $port]]
    }

    proc server-connect {sock host port} {
	variable tpid

	::thread::detach $sock
	set jid [tpool::post $tpid "::scgi::accept $sock $host $port"]
    }

    ###########################################################################
    # Connection handling
    #
    # Sub-package used for connections handled by each individual thread
    ###########################################################################

    variable thrscript {
	package require Thread 2.7
	package require ncgi 1.4
	package require json 1.1
	package require json::write 1.0

	namespace eval ::scgi:: {
	    namespace export accept \
			    get-header get-body-json \
			    set-header set-body set-json set-cookie \
			    serror \
			    output

	    #
	    # Name of the function (called in accept) to handle requests
	    # This variable is used in the ::scgi::start function.
	    #

	    variable handlefn

	    #
	    # Generate a Tcl stack trace in the message sent back
	    #

	    variable debug

	    #
	    # Global state associated with the current request
	    # - sock: socket to the client
	    # - reqhdrs: request headers
	    # - errcode: html error code, in case of error
	    # - rephdrs: reply headers
	    # - repbody: reply body
	    # - repbin: true if body is a binary format
	    # - cooktab: dict of cookies
	    # - done: boolean if output already done
	    #

	    variable state
	    array set state {
		sock {}
		reqhdrs {}
		errcode {}
		rephdrs {}
		repbody {}
		repbin {}
		cooktab {}
		done {}
	    }

	    #
	    # This function is called from the server thread
	    # by the ::scgi::server-connect function,
	    # indirectly by the tpool::post command.
	    # 

	    proc accept {sock host port} {
		variable handlefn
		variable debug
		variable state

		#
		# Get input socket
		#

		thread::attach $sock

		#
		# Reset global state
		#

		foreach k [array names state] {
		    set state($k) ""
		}
		set state(sock) $sock
		set state(done) false
		set state(errcode) 500
		set state(repbin) false

		try {
		    lassign [scgi-read $sock] state(reqhdrs) body

		    # Uncomment this line to display request headers
		    # array set x $state(reqhdrs) ; parray x ; puts stdout ""

		    set parm [parse-param $state(reqhdrs) $body]
		    set cookie [parse-cookie]
		    set uri [get-header SCRIPT_NAME "/"]
		    # normalize URI (apache does not dot it)
		    regsub -all {/+} $uri {/} uri
		    set meth [string tolower [get-header REQUEST_METHOD "get"]]

		    $handlefn $uri $meth $parm $cookie

		} on error msg {

		    if {$state(errcode) == 500} then {
			set-header Status "500 Internal server error" true
		    } else {
			set-header Status "$state(errcode) $msg" true
		    }

		    if {$debug} then {
			set-body "<pre>Error during ::scgi::accept</pre>"
			set-body "\n<p>\n"
			global errorInfo
			set-body "<pre>$errorInfo</pre>"
		    } else {
			set-body "<pre>The server encountered an error</pre>"
		    }
		}

		try {
		    output
		    close $sock
		}
	    }

	    #
	    # Decode input according to the SCGI protocol
	    # Returns a 2-element list: {<hdrs> <body>}
	    #
	    # Exemple from: https://python.ca/scgi/protocol.txt
	    #	"70:"
	    #   	"CONTENT_LENGTH" <00> "27" <00>
	    #		"SCGI" <00> "1" <00>
	    #		"REQUEST_METHOD" <00> "POST" <00>
	    #		"REQUEST_URI" <00> "/deepthought" <00>
	    #	","
	    #	"What is the answer to life?"
	    #

	    proc scgi-read {sock} {
		fconfigure $sock -translation {binary crlf}

		set len ""
		# Decode the length of the netstring: "70:..."
		while {1} {
		    set c [read $sock 1]
		    if {$c eq ""} then {
			error "Invalid netstring length in SCGI protocol"
		    }
		    if {$c eq ":"} then {
			break
		    }
		    append len $c
		}
		# Read the value (all headers) of the netstring
		set data [read $sock $len]

		# Read the final comma (which is not part of netstring len)
		set comma [read $sock 1]
		if {$comma ne ","} then {
		    error "Invalid final comma in SCGI protocol"
		}

		# Netstring contains headers. Decode them (without final \0)
		set hdrs [lrange [split $data \0] 0 end-1]

		# Get content_length header
		set clen [dget $hdrs CONTENT_LENGTH 0]

		set body [read $sock $clen]

		return [list $hdrs $body]
	    }

	    proc serror {code reason} {
		variable state

		set state(errcode) $code
		error $reason
	    }

	    proc get-header {key {defval {}}} {
		variable state
		return [dget $state(reqhdrs) $key $defval]
	    }

	    proc get-body-json {parm} {
		set btype [dict get $parm "_bodytype"]
		if {$btype ne "json"} then {
		    serror 404 "Invalid type (JSON expected)"
		}
		return [dict get $parm "_body"]
	    }

	    # check json attributes in the object against the
	    # specification (see below), and store
	    # individual values either in the array, or in variables
	    # named after the attribute name in the upper context.
	    # returns true if JSON input is valid, else false
	    # Note: spec is a list of {attrname type [defval]}
	    #	with type in {int inet4 text {}}

	    proc check-json-attr {object spec {_tab {}}} {
		if {$_tab ne ""} then {
		    upvar $_tab tab
		    set import false
		} else {
		    set import true
		}

		foreach s $spec {
		    lassign $s k type defval
		    set pos [lsearch -exact -index 0 $spec $k]
		    if {$pos == -1} then {
			return false
		    }
		    set v [dict get $object $k]
		    switch $type {
			{} {
			    # no type check
			    if {$v eq "null"} then {
				set v $defval
			    }
			}
			int {
			    if {$v eq "null"} then {
				set v $defval
			    }
			    if {[catch {expr $v+0}]} then {
				return false
			    }
			}
			inet4 {
			    if {$v eq "null"} then {
				set v $defval
			    }
			}
			text {
			    # null is not distinguishable from the string null
			}
			default {
			    return false
			}
		    }
		    if {$import} then {
			uplevel [list set $k $v]
		    } else {
			set tab($k) $v
		    }
		    set spec [lreplace $spec $pos $pos]
		}
		if {[llength $spec] > 0} then {
		    return false
		}
		return true
	    }

	    proc set-header {key val {replace {true}}} {
		variable state

		set key [string totitle $key]
		set val [string trim $val]

		if {$replace || ![dict exists $state(rephdrs) $key]} then {
		    dict set state(rephdrs) $key $val
		}
	    }

	    # Input:
	    #   - name: cookie name (printable ascii chars, excluding [,; =])
	    #   - val: cookie value (printable ascii chars, excluding [,; ])
	    #   - expire: unix timestamp, or 0 if no expiration date
	    #   - path:
	    #   - domain:
	    #   - secure:
	    #   - httponly:
	    # Output: none
	    #
	    # History:
	    #   2014/03/28 : pda/jean : design

	    proc set-cookie {name val expire path domain secure httponly} {
		variable state

		set l {}

		lappend l "$name=$val"
		if {$expire > 0} then {
		    # Wdy, DD Mon YYYY HH:MM:SS GMT
		    set max [clock format $expire -gmt yes -format "%a, %d %b %Y %T GMT"]
		    lappend "Expires=$max"
		}
		if {$path ne ""} then {
		    lappend "Path=$path"
		}
		if {$domain ne ""} then {
		    lappend "Domain=$domain"
		}
		if {$secure} then {
		    lappend "Secure"
		}
		if {$httponly} then {
		    lappend "HttpOnly"
		}

		dict set state(cooktab) $name [join $l "; "]
	    }

	    proc set-body {data {binary false}} {
		variable state

		set state(repbin) $binary
		append state(repbody) $data
	    }

	    proc set-json {dict} {
		set-header Content-Type application/json
		set-body [tcl2json $dict]
	    }

	    #
	    # See http://rosettacode.org/wiki/JSON#Tcl
	    #

	    proc tcl2json {value} {
		# Guess the type of the value; deep *UNSUPPORTED* magic!
		regexp {^value is a (.*?) with a refcount} \
		    [::tcl::unsupported::representation $value] -> type
	     
		switch $type {
		    string {
			return [json::write string $value]
		    }
		    dict {
			return [json::write object {*}[
			    dict map {k v} $value {tcl2json $v}]]
		    }
		    list {
			return [json::write array {*}[lmap v $value {tcl2json $v}]]
		    }
		    int - double {
			return [expr {$value}]
		    }
		    booleanString {
			return [expr {$value ? "true" : "false"}]
		    }
		    default {
			# Some other type; do some guessing...
			if {$value eq "null"} {
			    # Tcl has *no* null value at all; empty strings are semantically
			    # different and absent variables aren't values. So cheat!
			    return $value
			} elseif {[string is integer -strict $value]} {
			    return [expr {$value}]
			} elseif {[string is double -strict $value]} {
			    return [expr {$value}]
			} elseif {[string is boolean -strict $value]} {
			    return [expr {$value ? "true" : "false"}]
			}
			return [json::write string $value]
		    }
		}
	    }

	    proc output {} {
		variable state

		if {$state(done)} then {
		    return
		}

		fconfigure $state(sock) -encoding utf-8 -translation crlf

		if {$state(repbin)} then {
		    set clen [string length $state(repbody)]
		} else {
		    set u [encoding convertto utf-8 $state(repbody)]
		    set clen [string length $u]
		}

		set-header Status "200" false
		set-header Content-Type "text/html; charset=utf-8" false
		set-header Content-Length $clen

		# output registered cookies
		dict for {name val} $state(cooktab) {
		    set-header Set-Cookie $val false
		}

		foreach {k v} $state(rephdrs) {
		    puts $state(sock) "$k: $v"
		}
		puts $state(sock) ""
		flush $state(sock)

		if {$state(repbin)} then {
		    fconfigure $state(sock) -translation binary
		} else {
		    fconfigure $state(sock) -encoding utf-8 -translation lf
		}
		puts -nonewline $state(sock) $state(repbody)

		catch {close $state(sock)}

		set state(done) true
	    }

	    #
	    # Extract parameters
	    # - hdrs: the request headers
	    # - body: the request body, as a byte string
	    #
	    # Returns dictionary
	    #

	    proc parse-param {hdrs body} {
		variable state

		set parm [dict create]

		set query [dget $hdrs QUERY_STRING]
		set parm [keyval $parm [split $query "&"]]

		if {$body eq ""} then {
		    dict set parm _bodytype ""
		} else {
		    lassign [content-type $hdrs] ctype charset
		    switch -- $ctype {
			{application/x-www-form-urlencoded} {
			    dict set parm _bodytype ""
			    set parm [keyval $parm [split $body "&"]]
			}
			{application/json} {
			    dict set parm _bodytype "json"
			    dict set parm _body $body
			    dict set parm _bodydict [::json::json2dict $body]
			}
			default {
			    dict set parm _bodytype $ctype
			    dict set parm _body $body
			}
		    }
		}

		return $parm
	    }

	    #
	    # Import parameters from a dictionary into a specific namespace
	    # Use a fully qualified namespace (e.g.: ::foo for example)
	    # or variables in the uplevel scope.
	    #

	    proc import-param {dict {ns {}}} {
		if {$ns ne ""} then {
		    if {[namespace exists $ns]} then {
			namespace delete $ns
		    }
		    dict for {var val} $dict {
			namespace eval $ns [list variable $var $val]
		    }
		} else {
		    dict for {var val} $dict {
			uplevel [list set $var $val]
		    }
		}
	    }

	    #
	    # Extract individual parameters
	    # - parm: dictionary containing
	    #

	    proc keyval {parm lkv} {
		foreach kv $lkv {
		    if {[regexp {^([^=]+)=(.*)$} $kv foo key val]} then {
			set key [::ncgi::decode $key]
			set val [::ncgi::decode $val]
			dict lappend parm $key $val
		    }
		}
		return $parm
	    }

	    #
	    # Extract content-type from headers and returns
	    # a 2-element list: {<content-type> <charset>}
	    # Example : {application/x-www-form-urlencoded utf-8}
	    #

	    proc content-type {hdrs} {
		set h [dget $hdrs CONTENT_TYPE]
		set charset "utf-8"
		switch -regexp -matchvar m -- $h {
		    {^([^;]+)$} {
			set ctype [lindex $m 1]
		    }
		    {^([^;\s]+)\s*;\s*(.*)$} {
			set ctype [lindex $m 1]
			set parm [lindex $m 2]
			foreach p [split $parm ";"] {
			    lassign [split $p "="] k v
			    if {$k eq "charset"} then {
				set charset $v
			    }
			}
		    }
		    default {
			set ctype $h
		    }
		}
		return [list $ctype $charset]
	    }

	    #
	    # Parse cookies
	    # Returns a dictionary
	    #

	    proc parse-cookie {} {
		set cookie [dict create]
		set ck [get-header HTTP_COOKIE]
		foreach kv [split $ck ";"] {
		    if {[regexp {^\s*([^=]+)=(.*)} $kv foo k v]} then {
			dict set cookie $k $v
		    }
		}
		return $cookie
	    }

	    #
	    # Parse accept-language header and choose the
	    # appropriate language among those listed in the
	    # "avail" list
	    # accept-language is provided by the
	    # HTTP_ACCEPT_LANGUAGE SCGI header, whose value
	    # is a string under the RFC 2616 format
	    #	lang [;q=\d+], ...
	    #

	    proc get-locale {avail} {
		set accepted [string tolower [get-header HTTP_ACCEPT_LANGUAGE]]
		if {$accepted ne ""} then {
		    #
		    # Parse accept-language string and build two arrays:
		    # tabl($quality) {list of accepted languages}
		    # tabq($lang) $quality
		    #
		    foreach a [split $accepted ","] {
			regsub -all {\s+} $a {} a
			set s [split $a ";"]
			set lang [lindex $s 0]
			set q 1
			foreach param [lreplace $s 0 0] {
			    regexp {^q=([.0-9]+)$} $param foo q
			}
			lappend tabl($q) $lang
			set tabq($lang) $q
		    }
		    #
		    # If there is a sub-language-tag, add the
		    # language-tag if it does not exist.
		    # There may be any number of sub-tags (e.g
		    # en-us-nyc-manhattan)
		    #
		    foreach l [array names tabq] {
			set q $tabq($l)
			set ll [split $l "-"]
			while {[llength $ll] > 1} {
			    set ll [lreplace $ll end end]
			    set llp [join $ll "-"]
			    if {! [info exists tabq($llp)]} then {
				lappend tabl($q) $llp
				set tabq($llp) $q
			    }
			}
		    }

		    #
		    # Filter accepted languages by available languages
		    # using quality factor.
		    #
		    set avail [string tolower $avail]
		    set locale "C"
		    foreach q [lsort -real -decreasing [array names tabl]] {
			foreach l $tabl($q) {
			    if {[lsearch -exact $avail $l] != -1} then {
				set locale $l
				break
			    }
			}
			if {$locale ne "C"} then {
			    break
			}
		    }
		} else {
		    set locale "en"
		}
		return $locale
	    }

	    #
	    # Get a value from a dictionary, using a default value
	    # if key is not found.
	    #

	    proc dget {dict key {defval {}}} {
		if {[dict exists $dict $key]} then {
		    set v [dict get $dict $key]
		} else {
		    set v $defval
		}
		return $v
	    }
	}
    }
}
