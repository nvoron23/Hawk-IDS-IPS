#!/usr/bin/perl -T

use strict;
use warnings;

use DBD::mysql;
use POSIX qw(setsid), qw(strftime), qw(WNOHANG);

require "/usr/local/sbin/parse_config.pm";

import parse_config;
$SIG{"CHLD"} = \&sigChld;
$SIG{__DIE__}  = sub { logger(@_); };

$ENV{PATH} = '';        # remove unsecure path
my $VERSION = '5.0.0';

my $debug = 0;
$debug = 1 if (defined($ARGV[0]));

# This will be our function that will print all logger requests to /var/log/$logfile
sub logger {
	print HAWKLOG strftime('%b %d %H:%M:%S', localtime(time)) . ' ' . $_[0] . "\n" and return 1 or return 0;
}

# Get and return the primary ip address of the server from ip a l
sub get_ip {
	my @ip = ();
	open IP, "/sbin/ip a l |" or die "DIE: Unable to get local IP Address: $!\n";
	while (<IP>) {
		next if ($_ !~ /eth0$/);
		@ip = split /\s+/, $_;
		$ip[2] =~ s/\/[0-9]+//;
		logger("Server ip: $ip[2]") if ($debug);
	}
	close IP;
	return $ip[2];
}

# Compare the current attacker's ip address with the local ips (primary and localhost)
sub is_local_ip {
	my $local_ip = shift;
	my $current_ip = shift;
	my %never_block = ("$local_ip" => 1, "127.0.0.1" => 1);
	# Return 1 if the attacker ip is our own ip
	return 1 if (defined($never_block{$current_ip}) && $never_block{$current_ip});
	# Return 0 if the attacker ip is not local
	return 0;
}

# Check if hawk is already running
sub is_hawk_running {
	my $pidfile = shift;
	# hawk is not running if the pid file is missing
	return 0 if (! -e $pidfile);
	# get the old pid
	open PIDFILE, '<', $pidfile or return 0;
	my $old_pid = <PIDFILE>;
	close PIDFILE;
	# if the pid format recorded in the file is incorrect answer as like hawk is running. this shoud never happen!
	return 1 if ($old_pid !~ /[0-9]+/);
	# hawk is running if the pid from the pidfile exists as dir in /proc
	return 1 if (-d "/proc/$old_pid");
	# hawk is not running
	return 0;
}

sub close_stdh {
	my $logfile = shift;
	# Close stdin ...
	open STDIN, '<', '/dev/null' or return 0;
	# ... and stdout
	open STDOUT, '>>', '/dev/null' or return 0;
	# Redirect stderr to our log file
	open STDERR, '>>', "$logfile" or return 0;
	return 1;
}

# write the program pid to the $pidfile
sub write_pid {
	my $pidfile = shift;
	open PIDFILE, '>', $pidfile or return 0;
	print PIDFILE $$ or return 0;
	close PIDFILE;
	return 1;
}

# Clean the zombie childs!
sub sigChld {
	while (waitpid(-1,WNOHANG) > 0) {
		logger("The child has been cleaned!") if ($debug);
	}
}

# Store each attacker attempt to the database if $_[0] is 0
# Store the attacker's ip to the brootforce database if $_[0] 1
# The brootforce table is later checked by the cron
sub store_to_db {
	# $_[0] 0 for insert into failed_log || 1 for insert into broots a.k.a 0 for log_me || 1 for broot_me
	# $_[1] IP
	# $_[2] The service under attack - 0 = ftp, 1 = ssh, 2 = pop3, 3 = imap, 4 = webmail, 5 = cpanel
	# $_[3] The user who is bruteforcing only if $_[0] == log_me
	# $_[4] DB name
	# $_[5] DB user
	# $_[6] DB pass
	my $conn = DBI->connect_cached($_[4], $_[5], $_[6], { PrintError => 1, AutoCommit => 1 }) or return 0;

	# Store each failed attempt to the failed_log table
	if ($_[0] == 0) {
		my $log_me = $conn->prepare('INSERT INTO failed_log ( ip, service, "user" ) VALUES ( ?, ?, ? ) ') or return 0;
		$log_me->execute($_[1], $_[2], $_[3]) or return 0;
	} elsif ($_[0] == 1) {
		my $broot_me = $conn->prepare('INSERT INTO broots ( ip, service ) VALUES ( ?, ? ) ') or return 0;
		$broot_me->execute($_[1], $_[2]) or return 0;
	}

	$conn->disconnect;
	# return 1 on success
	return 1;
}

sub get_attempts {
	my $new_count = shift;
	my $current_attacker_count = shift;
	# Return the current number of bruteforce attempts for that ip if no old records has been found
	return $new_count if (! defined($current_attacker_count));
	# Sum the number of current bruteforce attempts for that ip with the recorded number of bruteforce attempts
	return $new_count + $current_attacker_count;
}

# Compare the number of failed attampts to the $max_attempts variable
sub check_broots {
	my $ip_failed_count = shift;
	my $max_attempts = shift;	# max number of attempts(for $broot_time) before notify

	# Return 1 if $ip_failed_count > $max_attempts
	# On return 1 the attacker's ip will be recorded to the store_to_db(broots) table
	return 1 if ($ip_failed_count >= $max_attempts);
	# Do not block/store if the broot attempts for this ip are less than the $max_attempts
	return 0;
}

# Parse the pop3/imap logs
sub pop_imap_broot {
	my @current_line = split /\s+/, $_;
	my $current_service = 3; # The default service id is 3 -> imap
	$current_service = 2 if ($current_line[5] =~ /pop3-login:/); # Service is now 2 -> pop3
	my $user = $_;
	my $ip = $_;
	my $attempts = $_;

	# Extract the user, ip and number of failed attempts from the log
	$user =~ s/^.* user=<(.+)>,.*$/$1/;
	$ip =~ s/^.* rip=([0-9.]+),.*$/$1/;
	$attempts =~ s/^.* ([0-9]+) attempts\).*$/$1/;
	chomp ($user, $ip, $attempts);

	# return ip, number of failed attempts, service under attack, failed username
	# this is later stored to the failed_log table via store_to_db
	return ($ip, $attempts, $current_service, $user);
}

sub ssh_broot {
	my $ip = '';
	my $user = '';
	my @sshd = split /\s+/, $_;

	if ( $sshd[8] =~ /invalid/ ) {
		#May 16 03:27:24 serv01 sshd[25536]: Failed password for invalid user suport from ::ffff:85.14.6.2 port 52807 ssh2
		#May 19 22:54:19 serv01 sshd[21552]: Failed none for invalid user supprot from 194.204.32.101 port 20943 ssh2
		$sshd[12] =~ s/::ffff://;
		$ip = $sshd[12];
		$user = $sshd[10];
		logger("sshd: Incorrect V1 $user $ip") if ($debug);
	} elsif ( $sshd[5] =~ /Invalid/) {
		#May 19 22:54:19 serv01 sshd[21552]: Invalid user supprot from 194.204.32.101
		$sshd[9] =~ s/::ffff://;
		$ip = $sshd[9];
		$user = $sshd[7];
		logger("sshd: Incorrect V2 $user $ip") if ($debug);
	} elsif ( $sshd[5] =~ /pam_unix\(sshd:auth\)/ ) {
		#May 15 09:39:10 serv01 sshd[9474]: pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=194.204.32.101  user=root
		$sshd[13] =~ s/::ffff://;
		$sshd[13] =~ s/rhost=//;
		$ip = $sshd[13];
		$user = $sshd[14];
		logger("sshd: Incorrect PAM $user $ip") if ($debug);
	} elsif ( $sshd[5] =~ /Bad/ ) {
		#May 15 09:33:45 serv01 sshd[29645]: Bad protocol version identification '0penssh-portable-com' from 194.204.32.101
		my @sshd = split /\s+/, $_;
		$sshd[11] =~ s/::ffff://;
		$ip = $sshd[11];
		$user = 'none';
		logger("sshd: Grabber $user $ip") if ($debug);
	} elsif ( $sshd[5] eq 'Failed' && $sshd[6] eq 'password' ) {
		#May 15 09:39:12 serv01 sshd[9474]: Failed password for root from 194.204.32.101 port 17326 ssh2
		#May 15 11:36:27 serv01 sshd[5448]: Failed password for support from ::ffff:67.15.243.7 port 47597 ssh2
		return undef if (! defined($sshd[10]));
		$sshd[10] =~ s/::ffff://;
		$ip = $sshd[10];
		$user = $sshd[8];
		logger("sshd: Incorrect V3 $user $ip") if ($debug);
	} else {
		logger("ssh_broot - unknown case. line: $_");
		# return undef if we do not know how to handle the current line. this should never happens.
		# if it happens we should create parser for $_
		return undef;
	}

	$_ =~ s/\'//g;
	# return ip, number of failed attempts, service under attack, failed username
	# this is later stored to the failed_log table via store_to_db
	# service id 1 -> ssh
	return ($ip, 1, 1, $user);
}

sub ftp_broot {
	# May 16 03:06:43 serv01 pure-ftpd: (?@85.14.6.2) [WARNING] Authentication failed for user [mamam]
	# Mar  7 01:03:49 serv01 pure-ftpd: (?@68.4.142.211) [WARNING] Authentication failed for user [streetr1] 
	my @ftp = split /\s+/, $_;	

	$ftp[5] =~ s/\(.*\@(.*)\)/$1/;	# get the IP
	$ftp[11] =~ s/\[(.*)\]/$1/;		# get the username
	# return ip, number of failed attempts, service under attack, failed username
	# this is later stored to the failed_log table via store_to_db
	# service id 0 -> ftp
	return ($ftp[5], 1, 0, $ftp[11]);
}

sub cpanel_webmail_broot {
	#209.62.36.16 - webmail.siteground216.com [07/17/2008:16:12:49 -0000] "GET / HTTP/1.1" FAILED LOGIN webmaild: user password hash is miss
	#201.245.82.85 - khaoib [07/17/2008:19:56:36 -0000] "POST / HTTP/1.1" FAILED LOGIN cpaneld: user name not provided or invalid user
	my @cpanel = split /\s+/, $_;
	my $service = 4; # Service type is webmail by default

	$service = 5 if ($cpanel[10] eq 'cpaneld:'); # Service type is cPanel if the log contains cpaneld:
	$cpanel[2] = 'unknown' if $cpanel[2] =~ /\[/;
	# return ip, number of failed attempts, service under attack, failed username
	# this is later stored to the failed_log table via store_to_db
	# service id 4 -> webmail
	# service id 5 -> cpanel
	return ($cpanel[0], 1, $service, $cpanel[2]);
}

# This is the main function which calls all other functions
# The entire logic is stored here
sub main {
	my $conf = '/home/sentry/hackman/hawk-web.conf';
	my %config = parse_config($conf);

	# Hawk files
	my $logfile = $config{'logfile'};	# daemon logfile
	$logfile = $1 if ($logfile =~ /^(.*)$/);
	# open the hawk log so we can immediately start logging any errors or debugging prints
	open HAWKLOG, '>>', $logfile or die "DIE: Unable to open logfile $logfile: $!\n";
	
	my $pidfile = $config{'pidfile'};	# daemon pidfile
	$pidfile  = $1 if ($pidfile =~ /^(.*)$/);

	# This is the system command that will monitor all log files
	# For our own convenience and so we can easily add new logs with new parsers the logs are defined in the conf
	# The logs should be space separated
	# If we need to monitor more logs just append them to the monitor_list conf var
	$config{'monitor_list'} = $1 if ($config{'monitor_list'} =~ /^(.*)$/);
	my $log_list = "/usr/bin/tail -s 1.00 -F --max-unchanged-stats=30 $config{'monitor_list'} |";
	
	# This is the lifetime of the broots hash
	# Each $broot_time all attacker's ips will be removed from the hash
	my $broot_time = $config{'broot_time'};
	
	my $start_time = time();

	# Store all attacker's ip addresses + the relevant information inside the hash array
	# Hash structure
	#	$hack_attempts{KEY} -> attacker's ip address
	#	$hack_attempts{ip}[0] -> total number of failed login attempts so far from that ip for ALL services
	#	$hack_attempts{ip}[1] -> service code of the last service where that ip failed to login/authenticate
	#	$hack_attempts{ip}[2] -> the last user which failed to authenticate from that ip
	#	$hack_attempts{ip}[3] -> is this ip address already stored to the broots table thus blocked. this is used so we can avoid adding duplicate entries for single ip
	#					 		 also this will avoid adding multiple iptables rules for a single ip
	my %hack_attempts = ();
	
	# What the name of the pid will be in ps auxwf :)
	$0 = $config{'daemon_name'};
	
	# input/output should be unbuffered. pass it as soon as you get it
	our $| = 1;
	
	# make sure that hawk is not running before trying to create a new pid
	# THIS SHOULD BE FIXED!!!
	if (is_hawk_running($pidfile)) {
		logger("is_hawk_running() failed");
		exit 1;
	}
	
	# Get the local primary ip of the server so we do not block it later
	# This open a security loop hole in case of local bruteforce attempts
	my $local_ip = get_ip();

	# me are daemon now :)
	defined(my $pid=fork) or die "DIE: Cannot fork process: $! \n";
	exit if $pid;
	setsid or die "DIE: Unable to setsid: $!\n";
	umask 0;

	# close stdin and stdout
	# redirect stderr to the hawk log
	if (! close_stdh($logfile)) {
		logger("close_stdh() failed");
		exit 1;
	}
	
	# write the new pid to the hawk pid file
	if (! write_pid($pidfile)) {
		logger("write_pid() failed");
		exit 1;
	}
	
	# use tail to open all logs that should be monitored
	open LOGS, $log_list or die "open $log_list with tail failed: $!\n";
	
	# make the output of the opened logs unbuffered
	select((select(HAWKLOG), $| = 1)[0]);
	select((select(LOGS), $| = 1)[0]);
	
	# this should never ends.
	# this is the main infinity loop
	# read each line and parse it. if we do not know how to handle it go to the next line
	while (<LOGS>) {
		# parse each known line
		# if this is a real attack from non local ip the attacker's ip, the number of failed attempts, the bruteforced service and the failed user are stored to @block_results

		# $block_results[0] - attacker's ip address
		# $block_results[1] - number of failed attempts. NOTE: This is the CURRENT number of failed attempts for that IP. The total number is stored in $hack_attempts{$ip}[0]
		# $block_results[2] - each service parser return it's own unique service id which is the id of the service which is under attack
		# $block_results[3] - the username that failed to authenticate to the given service
		my @block_results = undef;

		if ($_ =~ /pop3-login:|imap-login:/ && $_ =~ /auth failed/) { # This looks like a pop3/imap attack.
			logger ("calling pop_imap_broot") if ($debug);
			@block_results = pop_imap_broot($_); # Pass the log line to the pop_imap_broot parser and get the attacker's details
		} elsif ( $_ =~ /sshd\[[0-9].+\]:/) {
			next if ($_ !~ /Failed \w \w/ && $_ !~ /authentication failure/ && $_ !~ /Invalid user/i && $_ !~ /Bad protocol/); # This looks like sshd attack
			logger ("calling ssh_broot") if ($debug);
			@block_results = ssh_broot($_); # Pass it to the ssh_broot parser and get the attacker's results
		} elsif ($_ =~ /pure-ftpd:/ && $_ =~ /Authentication failed/) {
			logger ("calling ftp_broot") if ($debug);
			@block_results = ftp_broot($_);
		} elsif ($_ =~ /FAILED LOGIN/ && ($_ =~ /webmaild:/ || $_ =~ /cpaneld:/)) { # This looks like cPanel/Webmail attack
			logger ("calling cpanel_webmail_broot") if ($debug);
			@block_results = cpanel_webmail_broot($_); # Pass it to the cpanel_webmail_broot parser and get the attacker's results
	   	} else {
			next; # This does not look like a particular known attack so skip this line and go to the next log line
			# Please mind that we do not have to check for block results etc. if this is not an attack line
		}
	
		# $hack_attempts{KEY} -> attacker's ip address
		# $hack_attempts{ip}[0] -> total number of failed login attempts so far from that ip for ALL services
		# $hack_attempts{ip}[1] -> service code of the last service where that ip failed to login/authenticate
		# $hack_attempts{ip}[2] -> the last user which failed to authenticate from that ip
		# $hack_attempts{ip}[3] -> is this ip address already stored to the broots table thus blocked. this is used so we can avoid adding duplicate entries for single ip
		#				 		   also this will avoid adding multiple iptables rules for a single ip

		# $block_results[0] - attacker's ip address
		# $block_results[1] - number of failed attempts. NOTE: This is the CURRENT number of failed attempts for that IP. The total number is stored in $hack_attempts{$ip}[0]
		# $block_results[2] - each service parser return it's own unique service id which is the id of the service which is under attack
		# $block_results[3] - the username that failed to authenticate to the given service
		# If the service log parser returned valid attacker response instead of undef we store the attack attempt to the database
		if (@block_results > 1 && ! is_local_ip($local_ip, $block_results[0])) {
			# Update the total failed attempts for the particular ip. If this ip is unknown to us we init $hack_attempts hash key for it
			# The total failed attempts calculations are made by get_attempts() function
			$hack_attempts{$block_results[0]}[0] = get_attempts($block_results[1], $hack_attempts{$block_results[0]}[0]);
			# Store the service id of the last failed attempt for that ip
			$hack_attempts{$block_results[0]}[1] = $block_results[2];
			logger("got attacker. storing it to failed_log: 0, $block_results[0], $block_results[1], $block_results[1]");
			# Finally write down the failed attempt to the database
			# store_to_db arguments: 0 - store to failed_log, attacker ip, current number of failed attempts, failed username, .... db details
			if (! store_to_db(0, $block_results[0], $block_results[1], $block_results[1], $config{"db"}, $config{"dbuser"}, $config{"dbpass"})) {
				logger("store_to_db failed: 0, $block_results[0], $block_results[1], $block_results[1]!");
			}
		}

		# Check for broots as we just had one new failed attempt above
		while (my $ip = each (%hack_attempts)) {
			# Skip this ip if it is already added to the database
			logger("$ip is already added to the broots db") and next if (defined($hack_attempts{$ip}[3] && $hack_attempts{$ip}[3]));
			# Skip this ip if it's number of failed attempts are less than the required from the conf
			logger("$ip has $hack_attempts{$ip}[0] attempts. required $config{'max_attempts'} for block ") and next if (! check_broots($hack_attempts{$ip}[0], $config{"max_attempts"}));
			logger("store_to_db(broots): 1, $ip, $hack_attempts{$ip}[1], undef");
			# The current attacker got >= config{"max_attempts"} in less than $broot_time seconds
			# It will be handed over to the hawk.broots table for storage and later blocked by the hawk cron
			$hack_attempts{$ip}[3] = store_to_db(1, $ip, $hack_attempts{$ip}[1], undef, $config{"db"}, $config{"dbuser"}, $config{"dbpass"});
			# The return results from store_to_db are later passed to $hack_attempts{$ip}[3]
			# This means that we will not try to store the same ip again before the $hack_attempts hashes are cleaned
		}
	
		my $curr_time = time();
	
		# clean all %hack_attempts entries if the $broot_time from the conf passed
		if (($curr_time - $start_time) > $broot_time) {
			logger("Cleaning the faults hashes and resetting the timers") if ($debug);
			# clean the hack_attempts hash and reset the timer
			delete @hack_attempts{keys %hack_attempts};
			$start_time = time();	# set the start_time to now
		}
	}
	
	# We should never hit those unless we kill tail :)
	logger("Gone ...after the main loop");
	close LOGS;
	logger("Gone ...after we closed the logs");
	close STDIN;
	logger("Gone ...after we closed the stdin");
	close STDOUT;
	logger("Gone ...after we closed the stdout");
	close STDERR;
	logger("Gone ...after we closed the stderr");
	close HAWKLOG;
	exit 0;
}

main();

=head1 NAME

hawk.pl - SiteGround Commercial bruteforce monitoring detection and prevention daemon. 

=head1 SYNOPSIS

/path/to/hawk.pl [debug]

=head1 DESCRIPTION

hawk.pl also known as [Hawk] is a bruteforce monitoring detection and prevention daemon.

It monitors various CONFIGURABLE log files by using the GNU tail util.

The output from the logs is monitored for predefined patterns and later passed to different parsers depending on the service which appears to be under attack.

Currently [Hawk] is capable of detecting and blocking bruteforce attempts against the following services:

	- ftp - PureFTPD support only

	- ssh - OpenSSH support only

	- pop3 - Dovecot support only

	- imap - Dovecot support only

	- cPanel

	- cPanel webmail

	- more to come soon ... :)

Each failed login attempt is stored to a local USER CONFIGURABLE PostgreSQL database inside the failed_log table which is later used by hawk-web.pl for data visualization and stats.

In case of too many failed login attempts from a single IP address for certain predefined USER CONFIGURABLE amount of time the IP address is stored/logged to the same database but inside the broots table. The broots table is later parsed by the /root/hawk-blocker.sh which does the actual blocking of the IP via iptables.

=head1 PROGRAM FLOW

	- main() - init the vital variables and go to the main daemon loop.

	- parse_config() - get the conf variables.

	- is_hawk_running() - make sure that hawk is not already running.

	- get_ip() - get the main ip of the server.

	- fork.

	- close_stdh() - close stdin and stdout, redirect stderr to the logs.

	- write_pid() - write the new [Hawk] pid to the pidfile.

	- open the logs for monitoring.

	- MONITOR THE LOGS

	- pop_imap_broot(), ssh_broot(), ftp_broot(), cpanel_webmail_broot() - In case of hack attempt match the control is passed to line parser for the given service.

	- is_local_ip() - Make sure that the IP of the attacker is not the local IP. We do not want to block localhosts.

	- get_attempts() - In case of bruteforce attempt we initialize or calculate the total number of failed attempts for that ip with this function.

	- store_to_db() - We also store this particular attempt to the failed_log table.

	- Check all attackers stored in %hack_attempts.

	- check_broots() - Compare the number of failed attempts for the current IP address with the max allowed failed attempts

	- store_to_db() - If the IP reached/exceeded the max allowed failed attempts the IP is stored to the broots table

	- Clear ALL IP addresses stored in %hack_attempts ONLY if $broot_time (USER CONFIGURABLE) seconds has elapsed and reset the timer

	- Start over to MONITOR LOGS

=head1 IMPORTANT VARIABLES

	- $conf - Full path to the [Hawk] and hawk-web.pl configuration file

	- %config - Store all $k,$v from the conf file so we can easily refference them via the conf var name

	- $logfile - Full path to the hawk.pl log file

	- $pidfile - Full path to the hawk.pl pid file

	- $config{'monitor_list'} - Space separated list of log files that should be monitoried by hawk. All of them should be on a SINGLE line

	- $log_list - The system command that will be executed to monitor the commands

	- $broot_time - The amount of time in seconds that should elapse before clearing all hack attempts from the hash

	- %hack_attempts - PERSISTENT (well not exactly :) storage for the IP addressess of all attackers that failed to identify to a given service for the last $broot_time seconds. After that the hash is cleared

		$hack_attempts{ip}[0] - total number of failed login attempts so far from that ip for ALL services

		$hack_attempts{ip}[1] - service code of the last service where that ip failed to login/authenticate

		$hack_attempts{ip}[2] - the last user which failed to authenticate from that ip

		$hack_attempts{ip}[3] -> is this ip address already stored to the broots table thus blocked. this is used so we can avoid adding duplicate entries for single ip also this will avoid adding multiple iptables rules for a single ip

	- $local_ip - Primary IP address of the server

	- @block_results - Temporary storage for the results returned by the service_name_parsers. If no results it should be undef.
		
		$block_results[0] - attacker's ip address

		$block_results[1] - number of failed attempts as returned by the parser. NOTE: This is the CURRENT number of failed attempts for that IP. The total number is stored in $hack_attempts{$ip}[0]

		$block_results[2] - each service parser return it's own unique service id which is the id of the service which is under attack

		$block_results[3] - the username that failed to authenticate to the given service

=head1 FUNCTIONS

=head2 get_ip() - Get the primary ip address of the server

	Input: NONE

	Returns: Main ip address of the server

=head2 is_local_ip() - Compare the current attacker's ip address with the local server ip

	Input:
		$local_ip - the local ip address of the server previously obtained from get_ip()
		$current_ip - the ip attacker's address returned by the servive_name_parser

	Output:
		0 if the IP address does not seem to be local
		1 if the IP address appears to be local

=head2 is_hawk_running() - Check if hawk is already running

	Input: $pidfile - The full system path to the pid file

	Output:
		0 if the pid does not exists, the old pid left from previous hawk instances does not exist in proc
		1 if hawk is already running or we have problem with the pid format left by previous/current hawk instance

=head2 close_stdh() - Close STDIN, STDOUT and redirect STDERR to the log fil

	Input: $logfile - The full system path to the hawk.pl log file

	Output:
		0 on failure
		1 on success

=head2 write_pid() - Write the new hawk pid to the pid file

	Input: $pidfile - The full system path to the hawk pid file

	Ouput:
		0 on failure
		1 on success

=head2 sigChld() - Reaper of the dead childs

	Called only in case of SIG CHILD

	Input: None

	Output: None

=head2 store_to_db() - Store the attacker's ip address to the failed_log or broots tables depending on the case

	Input:
		$_[0] - Where we should store this attempt
			- 0 means failed_log
			- 1 means broots
		$_[1] - The attacker's ip address that should be recorded to the DB
		$_[2] - The code of the service which is under attack
		$_[3] - The username that the attacker tried to use to login. Correctly defined only in case $_[0] is 0. Otherwise it is undef
		$_[4] - DB name
		$_[5] - DB user
		$_[6] - DB pass

	Output:
		0 on failure - In such case we will retry to store the attacker later on the next loop :)
		1 on success

=head2 get_attempts() - Compute the number of failed attempts for the current attacker

	Input:
		$new_count - The number of failed attempts we just received from the service parser for that ip
		$current_attacker_count - The stored number of failed attempts for that ip. Undef if this is a new attacker

	Output:
		Total number of failed attempts (we just sum old+new or return new if old is undef)

=head2 check_broots() - Compare the number of failed attempts for this attacker with the $max_attempts CONF variable

	Input:
		$ip_failed_count - Total number of failed attempts from this IP address
		$max_attempts - The conf variable

	Output:
		0 if $ip_failed_count < $max_attempts
		1 if $ip_failed_count >= $max_attempts -> This means store this IP to the broots db and later block it with iptables via the cron

=head2 pop_imap_broot() ssh_broot() ftp_broot() cpanel_webmail_broot() - The logs output parsers for the supported services

	Input: $_ - The log line that looks like bruteforce attempt

	Output:
		$ip - The IP address of the attacker
		$num_failed - The number of failed attempts for that IP returned by the parser
		$service_id - The id/code of the service which is under attack
			0 - FTP
			1 - SSH
			2 - POP3
			3 - IMAP
			4 - WebMai
			5 - cPanel
		$username - The username that failed to authenticate from that IP

=head2 main() - NO HELP AVAIL :)

=head1 CONFIGURATION FILE and CONFIGURABLE parameters

	db - The name of the database where the data will be stored by the daemon
	
	dbuser - The name of the user which has the rights to connect and store info to the db

	dbpass - ...

	template_path - Path to the hawk templates. Used only by hawk-web.pl

	service_ids - service_name:id pairs. What is the ID of "this" service?

	service_names - id:service_name pairs. What is the name of "this" service id?

	logfile - The full system path to the hawk.pl log file

	monitor_list - The full space separated list of logfiles that should be monitored by [Hawk] via tail. Should be on a single line.

	broot_time - The max amount of time in seconds that should pass before we clear the stored attacker's from the hash

	max_attempts - The max number of failed attempts before we block the attacker's ip address

	daemon_name - The name of the hawk.pl daemon as it will appear in ps uaxwf

=head1 SUPPORTED DATABASE ENGINES

	PostgreSQL only so far. We do not plan to release MySQL support as MySQL .... a duck :)

=head1 REPORTING BUGS

	operations@siteground.com

=head1 COPYRIGHT

	FILL ME

=head1 SEE ALSO

	hawk-web.pl, hawk-web.conf, hawk-block.sh, hawk.init
=cut
