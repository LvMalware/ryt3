#!/usr/bin/env perl

use strict;
use warnings;
use HTTP::Tiny;
use File::Copy;
use Getopt::Long;
use File::Basename;
use IO::Socket::INET;
use Time::HiRes 'ualarm';
use Digest::SHA 'sha256_hex';

my $torrc = '/etc/tor/torrc';
my $virtnet = '10.192.0.0/10';
my $transport = 9040;
my $contrport = 9051;
my $dnsport = 5353;

sub help {
    my $prog = basename($0);
    print <<HELP;
$prog - Route your traffic through Tor
Usage: $prog [-h | --help] command

Commands:
    start       Start the transparent proxy and set up everything
    stop        Stop the proxy and restores normal network behaviour
    new         Get a new Tor circuit
    restart     Restart the proxy
    install     Install necessary packages

This program can be used to set up a transparent proxy using Tor and route all
your traffic through it. On your first use you must run '$prog install' to 
ensure all dependences are installed, before running '$prog start'
    
HELP
    0
}

sub get_subnets {
    my @nets = `ip a s` =~ /inet +(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d+)/ig;
    return @nets if @nets > 0;
    while (`ifconfig` =~ /inet +([^ ]+) +netmask +([^ ]+)/ig) {
        my ($ip, $mask) = ($1, $2);
        my $bin = join '', map { sprintf "%b", $_ } split /\./, $mask;
        $mask = length($bin =~ s/0+$//r);
        push @nets, "$ip/$mask";
    }
    @nets
}

sub tor_uid {
    chomp(my $id = `id tor 2>/dev/null` || `id debian-tor 2>/dev/null`);
    die "Can't get tor UID" unless $id;
    my ($uid) = $id =~ /uid=(\d+)/ig;
    $uid
}

sub start {
    print "[+] Setting up transparent proxy...\n";

    # backup torrc
    unless (-f "$torrc.bak") {
        copy($torrc, "$torrc.bak") || return 0;
    } else {
        # restore torrc to avoid dupplicated lines
        copy("$torrc.bak", $torrc);
    }
    # get tor daemon uid
    my $tor_uid = tor_uid();
    # get local subnets for which Tor should not be used
    my @subnets = get_subnets();
    # generte a random password for control port access
    my $password = sha256_hex(join '', map { rand 256 } 1 .. 32);
    # hash the password
    my ($hashed) = `tor --hash-password "$password"` =~ /(16:[a-f\d]+)/i;
    # config lines to add to torrc
    my $config =<<CONFIG;
VirtualAddrNetwork $virtnet
AutomapHostsOnResolve 1
TransPort $transport IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
ControlPort 127.0.0.1:$contrport
DNSPort $dnsport

TestSocks 1
WarnPlaintextPorts 21,23,109,110,143,80
ClientRejectInternalAddresses 1

NewCircuitPeriod 40
MaxCircuitDirtiness 600
MaxClientCircuitsPending 48

UseEntryGuards 1
EnforceDistinctSubnets 1

HashedControlPassword $hashed
# $password
CONFIG
    # add config lines
    open(my $fh, ">>$torrc") || return 0;
    print $fh $config;
    close $fh;

    # disable IPv6
    system("sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null");
    system("sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null");

    # flush iptables rules
    system("iptables -F");

    # any traffic coming from tor on nat will traverse the chain to the next ACCEPT target
    system("iptables -t nat -A OUTPUT -m owner --uid-owner $tor_uid -j RETURN");
    # redirect all DNS requests to be handled by the tor daemon
    system("iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports $dnsport");
    # traverse subnet traffic to the next ACCEPT target
    for my $subnet (@subnets) {
        system("iptables -t nat -A OUTPUT -d $subnet -j RETURN");
    }
    # redirect all traffic to the Tor transparent proxy port
    system("iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports $transport");
    # keep traffic of already stablished connections
    system("iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT");
    # allow traffic on the subnets to work normally (without tor)
    for my $subnet (@subnets) {
        system("iptables -A OUTPUT -d $subnet -j ACCEPT");
    }
    # allow any traffic generated by tor to exit
    system("iptables -A OUTPUT -m owner --uid-owner $tor_uid -j ACCEPT");
    # reject any other traffic
    system("iptables -A OUTPUT -j REJECT");

    # https://lists.torproject.org/pipermail/tor-talk/2014-March/032507.html
    system("iptables -A OUTPUT -m conntrack --ctstate INVALID -j DROP");
    system("iptables -A OUTPUT -m state --state INVALID -j DROP");
    system("iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,FIN ACK,FIN -j DROP");
    system("iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,RST ACK,RST -j DROP");

    # restart tor daemon
    system("service tor restart > /dev/null");
    1
}

sub new_identity {
    chomp(my $password = `tail -n 1 $torrc`);
    $password = (split(" ", $password))[1] || return;
    print "[+] Changing Tor identity ...\n";
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $contrport,
        Proto    => 'tcp',
    ) || die "[!] Can't connect to control port";
    print $sock "authenticate \"$password\"\n";
    print $sock "signal newnym\n";
    print $sock "quit\n";
    1;
}

sub stop {
    print "[+] Stopping transparent proxy...\n";

    # enable IPv6
    system("sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null");
    system("sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null");

    # flush all iptables rules on NAT and filters
    system("iptables -t nat -F OUTPUT");
    system("iptables -t filter -F OUTPUT");

    if ( -f "$torrc.bak" ) {
        # restore torrc
        system("mv $torrc.bak $torrc");
        # restart tor service
        system("service tor restart >/dev/null");
    }
    1
}

sub restart {
    stop() && start()
}

sub install {
    chomp(my $pkg = `which apt` || `which pacman` || `which dnf` || `xbps-install`);
    my $install = ($pkg =~ /(apt)|(dnf)$/) ? "install -y" : "-Sy";
    system("$pkg $install tor iptables");
    0
}

sub status {
    my ($try) = @_;
    my $http = HTTP::Tiny->new();
    my $sleep = 200000;
    my @status = split //, "\\|/-";
    my $i = 0;
    $SIG{ALRM} = sub {
        ualarm $sleep;
        print "\r[${\($status[$i++])}] Checking status ...";
        $| ++;
        $i %= @status;
    };
    ualarm $sleep;
    my $json = $http->get("https://check.torproject.org/api/ip")->{content};
    $SIG{ALRM} = sub {};
    sleep $sleep;
    print "\r[+] Checking status ...\n";
    my ($istor, $ip) = $json =~ /"IsTor":([^,]+),"IP":"([^"]+)"/g;
    if ($istor eq 'true') {
        print "[+] Running: You are now routing all your traffic through the Tor network\n"
    } else {
        print "[!] Stopped: You are NOT routing your traffic through Tor!\n";
    }
    print "[+] Your IP is: $ip\n" if $ip;
    0;
}

sub main {

    if ($> != 0) {
        print "[!] This program needs to run as root\n";
        return 1;
    }

    GetOptions(
        "h|help" => \&help,
    ) || die "Something went wrong";

    my $command = lc(shift @ARGV || "help");
    
    if ($command eq "start") {
        start();
    } elsif ($command eq "stop") {
        stop();
    } elsif ($command eq "restart") {
        restart();
    } elsif ($command eq "install") {
        return install();
    } elsif ($command eq "status") {
        return status();
    } elsif ($command eq "new") {
        new_identity();
    } else {
        return help();
    }
    status();
    0
}

exit main unless caller
