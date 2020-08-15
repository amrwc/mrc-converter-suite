#
# Copyright 2018 Mike Cappella (mike@cappella.us)

package Utils::PwCheck 1.00;

use v5.16;
use utf8;
use strict;
use warnings;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use Digest::SHA1 qw(sha1_hex);
use LWP::UserAgent;
use IO::Socket::SSL;
use Mozilla::CA;

use Utils::Utils;

#$DB::single = 1;
my $pwcheck_debug = 0;			# set for module debugging
my $ua;
my $site = 'https://api.pwnedpasswords.com';

sub init {
    setup_user_agent();
    $ua or bail "Failed to setup web connection";

    my ($code, undef) = get_url($site);
    bail "Aborting: password check site unavailable: $code: $site"	if $code != 200;
}

sub check_password {
    my $password = shift;

    my $sha1 	= uc sha1_hex($password);
    my $prefix	= substr($sha1, 0, 5);
    my $suffix	= substr($sha1, 5);

    $pwcheck_debug and debug "password: $password, SHA1: $sha1, prefix/suffix: ", join('/', $prefix, $suffix), "\n";

    # e.g. https://api.pwnedpasswords.com/range/47FE3
    my ($code, $data) = get_url(join '/', $site, 'range', $prefix);

    if ($code == 200) {
	$pwcheck_debug and debug "response is\n", $data, "\n";

	my %pwkeys;
	$data =~ s/^\x{FEFF}//;				# Remove the UTF-8 BOM
	for (split /\n/, $data) {
	    my ($hash, $count) = split /:/;
	    $pwkeys{$hash} = ($count =~ s/\r//r);
	}
	if (exists $pwkeys{$suffix}) {
	    debug "password compromised: '$password'";
	    return 1;
	}
    }
    elsif ($code != 404) {
	$pwcheck_debug and debug "code: $code";
    }

    return undef;
}

# setup and return the user agent
sub setup_user_agent {
    $ua = LWP::UserAgent->new(
	agent => $main::progstr,
	keep_alive => 10,
	);
    $ua->timeout(15);
    $ua->env_proxy;
}

# Get the content at the given URL
sub get_url {
    my $url = shift;

    $pwcheck_debug and debug("fetching URL: ", $url);
    my $response = $ua->get($url, 'Accept-Encoding' => 'gzip, deflate');
    unless ($response->is_success) {
	debug "Failed to get page: $url\n", $response->status_line;
	return ($response->code, undef);
    }

    return ($response->code, $response->decoded_content);
}

1;
