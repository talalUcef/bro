##! Scan detection
##!
##! ..Authors: Sheharbano Khattak
##!            Seth Hall
##!            All the authors of the old scan.bro

@load base/frameworks/notice
@load base/frameworks/metrics

module Scan;

export {
	redef enum Notice::Type += {
		## Address scans detect that a host appears to be scanning some number
		## of hosts on a single port. This notice is generated when more than 
		## :bro:id:`addr_scan_threshold` unique hosts are seen over the 
		## previous :bro:id:`addr_scan_interval` time range.
		Address_Scan,
		## Port scans detect that an attacking host appears to be scanning a 
		## single victim host on several ports.  This notice is generated when 
		## an attacking host attempts to connect to :bro:id:`port_scan_threshold` 
		## unique ports on a single host over the previous 
		## :bro:id:`port_scan_interval` time range.
		Port_Scan,
		};

	## Failed connection attempts are tracked over this time interval for the address 
	## scan detection.  A higher interval will detect slower scanners, but may 
	## also yield more false positives.
	const addr_scan_interval = 5min &redef;
	## Failed connection attempts are tracked over this time interval for the port 
	## scan detection.  A higher interval will detect slower scanners, but may 
	## also yield more false positives.
	const port_scan_interval = 5min &redef;

	## The threshold of a unique number of hosts a scanning host has to have failed 
	## connections with on a single port.
	const addr_scan_threshold = 25 &redef;
	## The threshold of a number of unique ports a scanning host has to have failed
	## connections with on a single victim host.
	const port_scan_threshold = 15 &redef;

	## Custom threholds based on service for address scan.  This is primarily 
	## useful for setting reduced thresholds for specific ports.
	const addr_scan_custom_thresholds: table[port] of count &redef;

	global Scan::addr_scan_policy: hook(scanner: addr, victim: addr, scanned_port: port);
	
	global Scan::port_scan_policy: hook(scanner: addr, victim: addr, scanned_port: port);
}


function check_addr_scan_threshold(index: Metrics::Index, val: Metrics::ResultVal): bool
	{
	# We don't need to do this if no custom thresholds are defined.
	if ( |addr_scan_custom_thresholds| == 0 )
		return F;

	local service = to_port(index$str);
	return ( service in addr_scan_custom_thresholds &&
	         val$sum > addr_scan_custom_thresholds[service] );
	}

function duration_to_mins_secs(dur: interval): string
	{
	local dur_count = double_to_count(interval_to_double(dur));
	return fmt("%dm%ds", dur_count/60, dur_count%60);
	}

function addr_scan_threshold_crossed(index: Metrics::Index, val: Metrics::ResultVal)
	{
	local side = Site::is_local_addr(index$host) ? "local" : "remote";
	local dur = duration_to_mins_secs(val$end-val$begin);
	local message=fmt("%s scanned %d unique hosts on port %s in %s", index$host, val$unique, index$str, dur);

	NOTICE([$note=Address_Scan,
	        $src=index$host,
	        $p=to_port(index$str),
	        $sub=side,
	        $msg=message,
	        $identifier=cat(index)]);
	}

function port_scan_threshold_crossed(index: Metrics::Index, val: Metrics::ResultVal)
	{
	local side = Site::is_local_addr(index$host) ? "local" : "remote";
	local dur = duration_to_mins_secs(val$end-val$begin);
	local message = fmt("%s scanned %d unique ports of host %s in %s", index$host, val$unique, index$str, dur);

	NOTICE([$note=Port_Scan, 
	        $src=index$host,
	        $dst=to_addr(index$str),
	        $sub=side,
	        $msg=message,
	        $identifier=cat(index)]);
	}

event bro_init() &priority=5
	{
	# Note: addr scans are trcked similar to:  table[src_ip, port] of set(dst);	
	Metrics::add_filter("scan.addr.fail", [$every=addr_scan_interval,
	                                       $measure=set(Metrics::UNIQUE),
	                                       $threshold_func=check_addr_scan_threshold,
	                                       $threshold=addr_scan_threshold,
	                                       $threshold_crossed=addr_scan_threshold_crossed]); 

	# Note: port scans are tracked similar to: table[src_ip, dst_ip] of set(port);
	Metrics::add_filter("scan.port.fail", [$every=port_scan_interval,
	                                       $measure=set(Metrics::UNIQUE),
	                                       $threshold=port_scan_threshold,
	                                       $threshold_crossed=port_scan_threshold_crossed]); 
	}

function add_metrics(id: conn_id, reverse: bool)
	{
	local scanner      = id$orig_h;
	local victim       = id$resp_h;
	local scanned_port = id$resp_p;

	if ( reverse )
		{
		scanner      = id$resp_h;
		victim       = id$orig_h;
		scanned_port = id$orig_p;
		}

	# Defaults to be implemented with a hook...
	#local transport_layer_proto = get_port_transport_proto(service);
	#if ( suppress_UDP_scan_checks && (transport_layer_proto == udp) )
	#	return F;
	#else if ( suppress_TCP_scan_checks && (transport_layer_proto == tcp) )
	#	return F;
	#else if ( suppress_ICMP_scan_checks && (transport_layer_proto == icmp) )
	#	return F;

	# TODO: all of this whitelist/blacklist will be done 
	#       through the upcoming hook mechanism
	# Blacklisting/whitelisting services
	#if ( |analyze_services| > 0 )
	#	{
	#	if ( service !in analyze_services )
	#		return F;
	#	}
	#else if ( service in skip_services )
	#	return F;
	#
	## Blacklisting/whitelisting subnets
	#if ( |analyze_subnets| > 0 && host !in analyze_subnets )
	#	return F;

	# Hooks don't seem to be working like I expected.  They'll have to wait a bit longer.
	
	#if ( hook Scan::addr_scan_policy(scanner, victim, scanned_port) )
		Metrics::add_data("scan.addr.fail", [$host=scanner, $str=cat(scanned_port)], [$str=cat(victim)]);

	#if ( hook Scan::port_scan_policy(scanner, victim, scanned_port) )
		Metrics::add_data("scan.port.fail", [$host=scanner, $str=cat(victim)], [$str=cat(scanned_port)]);
	}

function is_failed_conn(c: connection): bool
	{
	# Sr || ( (hR || ShR) && (data not sent in any direction) ) 
	if ( (c$orig$state == TCP_SYN_SENT && c$resp$state == TCP_RESET) ||
	     (((c$orig$state == TCP_RESET && c$resp$state == TCP_SYN_ACK_SENT) ||
	       (c$orig$state == TCP_RESET && c$resp$state == TCP_ESTABLISHED && "S" in c$history )
	      ) && /[Dd]/ !in c$history )
	   )
		return T;
	return F;
	}

function is_reverse_failed_conn(c: connection): bool
	{
	# reverse scan i.e. conn dest is the scanner
	# sR || ( (Hr || sHr) && (data not sent in any direction) ) 
	if ( (c$resp$state == TCP_SYN_SENT && c$orig$state == TCP_RESET) ||
	     (((c$resp$state == TCP_RESET && c$orig$state == TCP_SYN_ACK_SENT) ||
	       (c$resp$state == TCP_RESET && c$orig$state == TCP_ESTABLISHED && "s" in c$history )
	      ) && /[Dd]/ !in c$history )
	   )
		return T;
	return F;
	}

## Generated for an unsuccessful connection attempt. This 
## event is raised when an originator unsuccessfully attempted 
## to establish a connection. “Unsuccessful” is defined as at least 
## tcp_attempt_delay seconds having elapsed since the originator 
## first sent a connection establishment packet to the destination 
## without seeing a reply.
event connection_attempt(c: connection)
	{
	local is_reverse_scan = F;
	if ( "H" in c$history )
		is_reverse_scan = T;
	
	add_metrics(c$id, is_reverse_scan);
	}

## Generated for a rejected TCP connection. This event 
## is raised when an originator attempted to setup a TCP 
## connection but the responder replied with a RST packet 
## denying it.
event connection_rejected(c: connection)
	{
	local is_reverse_scan = F;
	if ( "s" in c$history )
		is_reverse_scan = T;
	
	add_metrics(c$id, is_reverse_scan);
	}

## Generated when an endpoint aborted a TCP connection. 
## The event is raised when one endpoint of an *established* 
## TCP connection aborted by sending a RST packet.
event connection_reset(c: connection)
	{
	if ( is_failed_conn(c) )
		add_metrics(c$id, F);
	else if ( is_reverse_failed_conn(c) )
		add_metrics(c$id, T);
	}

## Generated for each still-open connection when Bro terminates.
event connection_pending(c: connection)
	{
	if ( is_failed_conn(c) )
		add_metrics(c$id, F);
	else if ( is_reverse_failed_conn(c) )
		add_metrics(c$id, T);
	}
