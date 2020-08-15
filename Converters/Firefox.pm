# Firefox autofill converter
#
# Copyright 2019 Mike Cappella (mike@cappella.us)

# Based on the excellent work from:
#    https://github.com/kspearrin/ff-password-exporter

package Converters::Firefox;

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
use JSON::PP;
use Term::ReadKey;
use MIME::Base64;
use Encoding::BER;
use Digest::SHA1;
use Digest::HMAC qw/hmac/;

# Use Crypt::CBC module for decryption when available, otherwise fallback to calling openssl
my $can_CryptCBC;
BEGIN {
    eval "require Crypt::CBC";
    $can_CryptCBC = 1 unless $@;
}
#$can_CryptCBC = 0;				# uncomment to force use of openssl even when Crypt::CBC is present

use Utils::PIF;
use Utils::File;
use Utils::Utils;
use Utils::Normalize;

=pod

=encoding utf8

=head1 Firefox converter module

=head2 Platforms

=over

=item B<macOS>: Initially tested with version 64

=item B<Windows>: Initially tested with version 64

=back

=head2 Description

Converts your Firefox Logins & Passwords data to 1PIF for 1Password import.

=head2 Instructions

Quit Firefox before running the converter.

This converter does not require an export file; you do not need to supply one on the command line.
The converter finds your Firefox profile data and directly decrypts the found data files.
For each profile, it will ask if you want the profile converted, and if so, it will ask
for the master password for that profile.
Enter the profile's master password when requested.

=cut

my %card_field_specs = (
    login =>			{ textname => '', fields => [
	[ 'url',		0, qr/^url$/, ],
	[ 'username',		0, qr/^username$/, ],
	[ 'password',		0, qr/^password$/, ],
    ]},
    note =>			{ textname => '', fields => [
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

our (@dbfiles, @profile_names);
my (@firefox_profile_paths, $home);
if ($^O eq 'MSWin32') {
    $home = $ENV{'USERPROFILE'};
    push @firefox_profile_paths, join '/', $home, 'AppData/Roaming/Mozilla/Firefox';

}
else {
    $home = $ENV{'HOME'};
    #~/Library/Application\ Support/Firefox/Profiles/888qt0fe.default/
    push @firefox_profile_paths, join '/', $home, 'Library/Application Support/Firefox';
    #push @firefox_profile_paths, 'Library/Mozilla/Firefox';
}

my $BER = Encoding::BER->new();

sub do_init {
    # Pre-calculate the various DB files to use, so that converter_to_1p4.pl knows about them
    for (@firefox_profile_paths) {
	my $inifile = join '/', $_, 'profiles.ini';
	file_exists($inifile) or
	    bail "Profile does not exist: $inifile";

	my $contents = slurp_fileX($inifile, 'utf8', 'removebom') or
	    bail "Profile is empty or unreadable: $inifile";

	my @pdata;
	while ($contents =~ /^\[Profile([^\]])]\s+(.+?)\R\R/msg) {
	    push @pdata, { map {split /=/, $_} split /\R/, $2 };
	    my $profiledir	= $pdata[-1]{'IsRelative'} ? join('/', $_, $pdata[-1]{'Path'}) : $pdata[-1]{'Path'};
	    debug sprintf "Found profile '%s' at %s", $pdata[-1]{'Name'}, $profiledir;

	    my $key4db		= join '/', $profiledir, 'key4.db';
	    my $loginsdb	= join '/', $profiledir, 'logins.json';
	    my @missing;
	    push @missing, 'key4.db'	 	unless file_exists($key4db);
	    push @missing, 'logins.json'	unless file_exists($loginsdb);
	    if (@missing) {
		debug sprintf "    Skipping profile '%s' - missing database file%s: @missing", $pdata[-1]{'Name'}, @missing > 1 ? 's' : '';
		next;
	    }
	    push @dbfiles, $key4db, $loginsdb;
	    push @profile_names,  $pdata[-1]{'Name'};
	}
    }

    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [],
	'files'		=> \@dbfiles,			# converter discovers files to use (no export file required)
    }
}

sub do_import {
    my (undef, $imptypes) = @_;

    my %datekeys = (
	timePasswordChanged	=> 'modified',
	timeCreated		=> 'created',
    );
    my %Cards;
    my $n = 1;

    while (@dbfiles) {
	my $key4db		= shift @dbfiles;
	my $loginsdb		= shift @dbfiles;
	my $profile_name	= shift @profile_names;

	my $response;
	printf "Profile '%s' at %s\n", $profile_name, ($key4db =~ s/\/key4\.db$//r);
	do {
	    print "    Convert it? [Y to convert, N to skip] ";
	    select()->flush();
	    chomp($response = <STDIN>);
	} until ($response =~ s/^\s*([yn])\s*$/$1/i);
	if ($response =~ /n/i) {
	    say "    Skipping profile '$profile_name'";
	    next;
	}

	my $key;
	my $max_attempts = 3;
	for (my $i = 1; $i <= $max_attempts; $i++) {
	    # Get the profile's master password to decrypt its login data
	    print "    Enter the profiles master password [just hit Enter if none]: ";
	    ReadMode('noecho');
	    chomp(my $password = <STDIN>);
	    ReadMode(0);
	    print "\n";

	    $key = getKey($password, $key4db);
	    last if $key;

	    say "\tMaster password is incorrect (attempt $i of $max_attempts)";
	}
	if (! $key) {
	    say "\tPassword attempts exceeded - skipping profile";
	    next;
	}

	print "\n";

	my $json = getLoginData($loginsdb);

	for (@{$json->{'logins'}}) {
	    my (%cmeta, @fieldlist);
	    my $itype = 'login';
	    next if defined $imptypes and (! exists $imptypes->{$itype});

	    $cmeta{'type'}	= $itype;
	    $cmeta{'title'} = ($_->{'hostname'} =~ s#https?://([^/]+).*$#$1#r) // 'Unknonwn';

	    my $h;
	    for my $up (qw /Username Password/) {
		my $d   = decryptLoginData($_->{'encrypted' . $up});
		my $dec = decrypt($d->{'data'}, $d->{'iv'}, $key);
		push @fieldlist, [ lc $up => $dec ]			if defined $dec and $dec ne '';
	    }
	    push @fieldlist, [ 'url' => $_->{'hostname'} ]		if defined $_->{'hostname'} and $_->{'hostname'} ne '';

	    for my $datekey (keys %datekeys) {
		if (defined $_->{$datekey} and $_->{$datekey} ne '') {
		    $_->{$datekey} /= 1000;
		    if ($main::opts{'notimestamps'}) {
			push @fieldlist, [ 'Date ' . ucfirst($datekeys{$datekey}), scalar localtime $_->{$datekey} ];
		    }
		    else {
			$cmeta{$datekeys{$datekey}} = $_->{$datekey};
		    }
		}
	    }

	    debug "\t$_->[0]: $_->[1]"	for @fieldlist;

	    my $normalized = normalize_card_data(\%card_field_specs, $itype, \@fieldlist, \%cmeta);
	    my $cardlist   = explode_normalized($itype, $normalized);

	    for (keys %$cardlist) {
		print_record($cardlist->{$_});
		push @{$Cards{$_}}, $cardlist->{$_};
	    }
	    $n++;
	}
    }

    summarize_import('item', $n - 1);
    return \%Cards;
}

sub do_export {
    add_custom_fields(\%card_field_specs);
    create_pif_file(@_);
}

sub getLoginData {
    my $file = shift;
    my $logins_data = slurp_fileX($file, 'utf8', 'removebom');
    my $json = decode_json $logins_data;
    return $json;
}

sub getKey {
    my ($master_password, $keyfile) = @_;

    my ($sth, $dbh, $ret);

    my $dbname = 'key4.db';
    debug "*** Connecting to Firefox $dbname key database";

    $dbh = DBI->connect("dbi:SQLite:dbname=$keyfile", "", "") or
	bail "Unable to open Firefox $dbname DB file: $keyfile\n$DBI::errstr";

    $sth = $dbh->prepare("SELECT item1, item2 FROM metadata WHERE id = 'password';");
    $sth->execute();
    for (@{$sth->fetchall_arrayref()}) {
	my ($globalsalt, $item2) = @$_;
	my $item2Asn1 = $BER->decode( $item2 );
	my $item2data = $item2Asn1->{'value'}[1]->{'value'};
	my $item2salt = $item2Asn1->{'value'}[0]->{'value'}[1]->{'value'}[0]->{'value'};
	my $val = decryptKey($globalsalt, $master_password, $item2salt, $item2data);
	if ($val eq 'password-check') {
	    debug "Master password looks good";

	    my $priv = $dbh->prepare("SELECT a11 FROM nssPrivate WHERE a11 IS NOT NULL;");
	    $priv->execute();
	    for (@{$priv->fetchall_arrayref()}) {
		my ($nssData) = @$_;
		my $a11Asn1 = $BER->decode($nssData);
		my $a11Salt = $a11Asn1->{'value'}[0]->{'value'}[1]->{'value'}[0]->{'value'};
		my $a11Data = $a11Asn1->{'value'}[1]->{'value'};
		my $a11Value = decryptKey($globalsalt, $master_password, $a11Salt, $a11Data);
		$ret = substr $a11Value, 0, 24;
	    }
	    $priv->finish();
	}
    }
    $sth->finish();
    debug "--- Done decoding $dbname";
    $dbh->disconnect();
    debug "*** Disconnecting from database";

    return $ret;
}

sub decryptKey {
    my ($globalSalt, $password, $entrySalt, $data) = @_;
    my $hp = Digest::SHA1::sha1($globalSalt . $password);
    my $pes = $entrySalt . pack("a" x (abs(20 - length $entrySalt) % 20));
    my $chp = Digest::SHA1::sha1($hp . $entrySalt);
    my $k1 = hmac($pes . $entrySalt, $chp, \&Digest::SHA1::sha1);
    my $tk = hmac($pes, $chp, \&Digest::SHA1::sha1);
    my $k2 = hmac($tk . $entrySalt, $chp, \&Digest::SHA1::sha1);
    my $k = $k1 . $k2;
    my $otherLength = length($k) - 32;
    my $key = substr($k, 0, 24);
    my $iv  = substr($k, -8);
    my $d =  decrypt($data, $iv, $key);
    return $d;
}

sub decrypt {
    my ($data, $iv, $key) = @_;

    my $plain;
    # macOS does not have any Perl Crypt libraries, so openssl is used for most people
    if ($can_CryptCBC) {
	my $cipher = Crypt::CBC->new(
		-cipher => 'DES_EDE3',
		-key => $key,
		-literal_key => 1,
		-iv => $iv,
		-add_header => 0,
		-keysize => length $key,
	);

	$plain = $cipher->decrypt($data);
	#printf "Crypto  %s, keylen: %d (%d), datalen: %d\n", hexdump($plain), length $key, length unpack("H*", $key), length $data;
    }
    else {
	my $keyH = unpack("H*", $key);
	my $ivH  = unpack("H*", $iv);
	# don't use openssl > 1.0.1m  - causes "hex string is too long" errors
	# https://mta.openssl.org/pipermail/openssl-bugs-mod/2016-May/000670.html
	my $data64 = MIME::Base64::encode_base64($data, "");
	my $algo = 'des-ede3-cbc';
	$keyH = substr $keyH, 0, 48		if $keyH ne '' and length $keyH > 48;	# avoid openssl "hex string is too long" error
	$plain = qx(printf "%s" "$data64" | /usr/bin/openssl $algo -d -a -A -iv "$ivH" -K "$keyH" -nosalt 2>&1);
	if ($plain =~ /bad decrypt\n.*:error:/ms) {
	    return '';
	}
	if ($plain =~ /hex string is too long/ms) {
	    bail "openssl error: $plain";
	}

	#printf "OPENSSL  %s, keylen: %d (%d), datalen: %d\n\n", hexdump($plain), length $key, length $keyH, length $data64;

    }
    return $plain;
}

sub decryptLoginData {
    my $enc = shift;
    my $dec = MIME::Base64::decode_base64($enc);

    my $ret = $BER->decode($dec);
    return { 
	iv	=> $ret->{'value'}[1]{'value'}[1]{'value'},
        data	=> $ret->{'value'}[2]{'value'}
    };
}

1;
