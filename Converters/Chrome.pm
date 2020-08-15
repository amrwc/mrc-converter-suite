# Chrome autofill converter (logins,credit cards)
#
# Copyright 2018 Mike Cappella (mike@cappella.us)

package Converters::Chrome;

our @ISA 	= qw(Exporter);
our @EXPORT     = qw(do_init do_import do_export);
our @EXPORT_OK  = qw();

use v5.14;
use utf8;
use strict;
use warnings;
#use diagnostics;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use DBI;
use MIME::Base64;
use File::Glob ':bsd_glob';
use if $^O eq 'darwin',		'PBKDF2::Tiny';
use if $^O eq 'MSWin32',	'Win32::API';

use Utils::PIF;
use Utils::Utils;
use Utils::Normalize;

=pod

=encoding utf8

=head1 Chrome converter module

=head2 Platforms

=over

=item B<macOS>: 65.0.3325.146 tested, earlier versions probably work

=item B<Windows>: 65.0.3325.146 tested, earlier versions probably work

=back

=head2 Description

This converter decrypts and converts your Chrome Logins and Credit Card profile data.

=head2 Instructions

You do not need to supply a file name on the command line.

On B<macOS>, the converter will cause two password dialogs to be presented, requesting access to your macOS Login keychain and the Chrome-specific password record that protects your Chrome storage (this key is required to decrypt your encrypted Chrome autofill entries).
Supply the passwords when requested.

After exporting your data, you must quit Chrome before running the converter.

=head2 Options

The C<< --username >> option allows you to reject any entry in the saved passwords list if the username
does not match the specified E<lt>stringE<gt> argument.
THe I<E<lt>stringE<gt>> argument can be string or a regular expression pattern.
The default is an exact string match.
To match using a regular expression, surround I<E<lt>stringE<gt>> with forward-slashes, with an optional trailing B<i> to ignore case.

Example: C<< --username /mrc/i >> will match B<MrC> and B<mrc> anywhere in the username component.

=cut

my %card_field_specs = (
    creditcard =>		{ textname => '', fields => [
	[ 'ccnum',		0, qr/^ccnum$/, ],
	[ 'cardholder',		0, qr/^cardholder$/, ],
	[ 'expiry',		0, qr/^expiry$/, ],
    ]},
    login =>			{ textname => '', fields => [
	[ 'url',		0, qr/^url$/, ],
	[ 'username',		0, qr/^username$/, ],
	[ 'password',		0, qr/^password$/, ],
    ]},
    note =>			{ textname => '', fields => [
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

our $username_re;

my @dbfiles;
my ($chrome_data_path, $home, $pathsep);
if ($^O eq 'MSWin32') {
    $chrome_data_path = 'AppData\Local\Google\Chrome\User Data';
    $home = $ENV{'USERPROFILE'};
    $pathsep = '\\';
}
else {
    $chrome_data_path = 'Library/Application Support/Google/Chrome';
    $home = $ENV{'HOME'};
    $pathsep = '/';
}

sub do_init {
    # Pre-calculate the various DB files to use, so that converter_to_1p4.pl knows about them
    for my $dbname ('Login Data', 'Web Data') {
	for my $dbfile (bsd_glob join($pathsep, $home, $chrome_data_path, '*', $dbname)) {
	     if (GLOB_ERROR) {
		# an error occurred reading $homedir
		bail "GLOB ERROR\n";
	    }
	    push @dbfiles, $dbfile;
	}
    }

    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [],
	'opts'          => [ [ q{      --username <str>     # username must match str (use /str/i for RE, optional i ignores case) },
			       'username=s' ],
		   	],
	'files'		=> \@dbfiles,		# converter discovers files to use (no export file required)
    }
}

sub get_db_entries {
    my ($safe_storage_key) = @_;

    my ($sth, $dbh, @entries);

    for my $dbfile (@dbfiles) {
	$dbfile =~ m#[/\\]((?:Web|Login) Data)$#;
	my $dbname = $1;

	debug "*** Connecting to chrome $dbname Data database";
	$dbh = DBI->connect("dbi:SQLite:dbname=$dbfile", "", "") or
	    bail "Unable to open chrome $dbname DB file: $dbfile\n$DBI::errstr";

	if ($dbname eq 'Login Data') {
	    $sth = $dbh->prepare("SELECT username_value, password_value, origin_url from logins");
	    $sth->execute();
	    for (@{$sth->fetchall_arrayref()}) {
		my ($username, $password, $url) = @$_;
		my $h;
		debug "Login entry";
		if (defined $username and $username ne '') {
		    if ($username_re and $username !~ $username_re) {
			verbose "Skipping unmatched username: $username";
			next;
		    }
		    $h->{'username'}	= $username;
		}
		$h->{'password'}	= decrypt($password, $safe_storage_key)		if defined $password and $password ne '';
		$h->{'url'}		= $url						if defined $url and $url ne '';
		$h->{'type'}		= 'login';
		debug "\t$_: $h->{$_}"	for keys %$h;
		push @entries, [ $h ];
	    }
	}
	else {
	    $sth = $dbh->prepare("select name_on_card, card_number_encrypted, expiration_month, expiration_year from credit_cards");
	    $sth->execute();

	    for (@{$sth->fetchall_arrayref()}) {
		my ($cardholder, $ccnum, $exp_month, $exp_year) = @$_;
		my $h;
		debug "Credit Card entry";
		$h->{'type'}		= 'creditcard';
		$h->{'cardholder'}	= $cardholder					if defined $cardholder and $cardholder ne '';
		$h->{'ccnum'}		= decrypt($ccnum, $safe_storage_key)		if defined $ccnum and $ccnum ne '';
		$h->{'expiry'}		= sprintf("%4d%02d", $exp_year, $exp_month)  	if $exp_month and $exp_year;
		debug "$_: $h->{$_}"	for keys %$h;
		push @entries, [ $h ];
	    }
	}

	$sth->finish();
	debug "--- Done decoding $dbname";
	$dbh->disconnect();
	debug "*** Disconnecting from database";
    }

    return @entries;
}

sub do_import {
    my (undef, $imptypes) = @_;

    if (exists $main::opts{'username'}) {
	if ($main::opts{'username'} =~ m#^(?<slash>/?)(.+?)\k<slash>([i]*)$#) {
	    my ($type,$pat,$flags) = ($1,$2,$3);
	    $username_re = $type eq '/' ? qr/(?$flags)$pat/ : qr/^\Q$pat\E$/;
	}
    }

    my $safe_storage_key;
    if ($^O eq 'darwin') {
	chomp ($safe_storage_key =  qx(security find-generic-password -wa Chrome));
	my $retcode = $? >> 8;
	if ($retcode) {
	    if ($retcode == 128) {
		say "Aborted";
		return undef;
	    }
	    bail "The security command failed to get Chrome safe storage key: ", qx(security error $retcode);
	}
	bail 'Aborting - the Chrome safe storage key is unexpectedly empty.'	 if $safe_storage_key eq '';
    }

    my %Cards;
    my $n = 1;
    for (get_db_entries($safe_storage_key)) {
	my $h = $_->[0];
	my $itype = $h->{'type'};
	next if defined $imptypes and (! exists $imptypes->{$itype});
	delete $h->{'type'};

	my %cmeta;
	if ($itype eq 'login') {
	    $cmeta{'title'} = ($h->{'url'} =~ s#https?://([^/]+).*$#$1#r);
	}
	elsif ($itype eq 'creditcard') {
	    $cmeta{'title'} = 'Card ending ' . last4($h->{'ccnum'});
	}
	else {
	    $cmeta{'title'} = 'Unknown';
	}
	my @fieldlist;
	for (keys %$h) {
	    push @fieldlist, [ $_ => $h->{$_} ];
	}

	my $normalized = normalize_card_data(\%card_field_specs, $itype, \@fieldlist, \%cmeta);
	my $cardlist   = explode_normalized($itype, $normalized);

	for (keys %$cardlist) {
	    print_record($cardlist->{$_});
	    push @{$Cards{$_}}, $cardlist->{$_};
	}
	$n++;
    }

    summarize_import('item', $n - 1);
    return \%Cards;
}

sub do_export {
    add_custom_fields(\%card_field_specs);
    create_pif_file(@_);
}

sub decrypt {
    my ($encrypted, $safe_storage_key) = @_;

    my $decrypted = '';
    if ($^O eq 'MSWin32') {
	# taken from: https://gist.github.com/DakuTree/98c8362fb424351b803e
	if ($encrypted ne '') {
	    my $pDataIn = pack('LL', length($encrypted) + 1, unpack('L!', pack('P', $encrypted)));
	    my $DataOut;
	    my $pDataOut = pack('LL', 0, 0);

	    my $CryptUnprotectData = Win32::API->new('crypt32', 'CryptUnprotectData', ['P', 'P', 'P', 'P', 'P', 'N', 'P'], 'N');
	    if ($CryptUnprotectData->Call($pDataIn, pack('L', 0), 0, pack('L', 0), pack('L4', 16, 0, 0, unpack('L!', pack('P', 0))), 0, $pDataOut)) {
		my ($len, $ptr) = unpack('LL', $pDataOut);
		$decrypted = unpack('P'.$len, pack('L!', $ptr));
	    }
	    else {
		my $err = Win32::GetLastError();
		bail "Crypt32 / CryptUnprotectData called failed ($err): ", Win32::FormatMessage($err);
	    }
	}
    }
    else {
	# taken from: https://github.com/manwhoami/OSXChromeDecrypt/blob/master/chrome_passwords.py
	my $iters = 1003;
	my $salt = 'saltysalt';
	my $iv = '20' x 16;

	my $key = substr(PBKDF2::Tiny::derive('SHA-1', $safe_storage_key, $salt, $iters), 0, 16);
	my $keyH = unpack("H*", $key);
	#say "Hexkey: $keyH";
	my $hex_enc_password = substr(encode_base64($encrypted, ''), 4);

	# don't use openssl > 1.0.1m  - causes "hex string is too long" errors
	my $ret = qx(printf "%s" $hex_enc_password | /usr/bin/openssl enc -a -A -d -aes-128-cbc -iv "$iv" -K "$keyH" 2>&1);
	if ($ret =~ /bad decrypt\n.*:error:/ms) {
	    debug "Decryption failed";
	    $decrypted = '';
	}
	else {
	    $decrypted = $ret;
	}
    }

    return $decrypted;
}

sub last4 {
    local $_ = shift;
    s/[- ._:]//;
    /(.{4})$/;
    return $1;
}

1;
