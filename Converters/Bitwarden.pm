# Bitwarden JSON export converter
#
# Copyright 2018 Mike Cappella (mike@cappella.us)

package Converters::Bitwarden;

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

use Utils::PIF;
use Utils::Utils;
use Utils::Normalize;

use Encode;
use JSON::PP;

=pod

=encoding utf8

=head1 Bitwarden converter module

=head2 Platforms

=over

=item B<macOS>:  Unable to test version 1.1.12 (due to a login screen bug)

=item B<Windows>: Initially tested with version 1.1.12

=back

=head2 Description

Converts your exported Bitwarden data to 1PIF for 1Password import.

=head2 Instructions

Launch either the desktop version of Bitwarden, or login into your Bitwarden vault via your browser.
You will export your Bitwarden data as B<JSON> data.

B<Exporting using the desktop app>:
Use the C<File E<gt> Export Vault> menu.
When the C<EXPORT VAULT> dialog appears, set the C<File Format> to C<.json>.
Provide your master password, and click the download button icon (at the bottom left of the dialog).
In the C<Save As> dialog, navigate to your B<Desktop> folder, and save the file with the name B<pm_export> to your Desktop.

B<Exporting using the browser>:
Log into your Bitwarden vault using your browser.
Click on the C<Tools> item at the top of the page.
Click on the C<Export Vault> item in the left side bar under the C<Tools> section.
Set the C<File Format> to C<.json>.
Provide your master password, and click the C<Export Vault> button.
When the browser's dialog appears, save the export - it will be saved to your browser's downloads area.
Find the exported JSON file in your browser's downloads area.
The downloaded file will be named something like I<bitwarden_export_20190309125037>.
Move this file to your Desktop.
That will be the file name you supply to the converter (you may rename it).

You may now quit Bitwarden.

=head2 Notes

Attachments are not exported by Bitwarden..
Be sure to download any attachments you have saved in your Bitwarden vault.

=cut

my %card_field_specs = (
    creditcard =>		{ textname => 'card', fields => [
	[ 'cardholder',		0, qr/^cardholderName$/, ],
	[ 'type',		0, qr/^brand$/, ],
	[ 'ccnum',		0, qr/^number$/, ],
	[ 'expiry',		0, qr/^expiry$/, ],
	[ 'cvv',		0, qr/^code$/, ],
    ]},
    identity =>			{ textname => 'identity', fields => [
	[ '_title',		0, qr/^title$/, ],
	[ 'firstname',		0, qr/^firstName$/, ],
	[ '_middle',		0, qr/^middleName$/, ],
	[ 'lastname',		0, qr/^lastName$/, ],
	[ 'company',		0, qr/^company$/, ],
	[ 'email',		0, qr/^email$/, ],
	[ 'defphone',		0, qr/^phone$/, ],
	[ 'username',		0, qr/^username$/, ],
	[ 'address',		0, qr/^ADDRESS$/, ],
	[ 'number',		0, qr/^ssn$/,  				{ type_out => 'socialsecurity' } ],
	[ 'number',		0, qr/^passportNumber$/,  		{ type_out => 'passport' } ],
	[ 'number',		0, qr/^licenseNumber$/,  		{ type_out => 'driverslicense' } ],
    ]},
    login =>			{ textname => 'login', fields => [
	[ 'username',		0, qr/^username$/, ],
	[ 'password',		0, qr/^password$/, ],
	[ 'url',		0, qr/^uri$/, ],
	[ '_totp',		0, qr/^totp$/, ],
	[ '*additionalurls',	0, qr/^additionalurls$/, ],

    ]},
    note =>			{ textname => 'secureNote', fields => [
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [ ],
    }
}

sub do_import {
    my ($file, $imptypes) = @_;
    my %Cards;

    my $data = slurp_file($file, 'utf8');

    my $n;
    if ($data =~ /^\{/ and $data =~ /\}$/) {
	$n = process_json(\$data, \%Cards, $imptypes);
    }

    summarize_import('item', $n - 1);
    return \%Cards;
}

sub process_json {
    my ($data, $Cards, $imptypes) = @_;
    my %Folders;

    my %uri_match_types = (
	0 => { use => 1, name => 'base domain' },
	1 => { use => 1, name => 'host' },
	2 => { use => 0, name => 'starts with' },
	3 => { use => 1, name => 'exact' },
	4 => { use => 0, name => 'regular expression' },
	5 => { use => 0, name => 'never' },
    );

    my $decoded = decode_json Encode::encode('UTF-8', $$data);

    exists $decoded->{'items'} or
	bail "Unable to find any items in the Bitwarden JSON export file";

    # Process any folders
    for my $folder ( exists $decoded->{'folders'} ? @{$decoded->{'folders'}} : () ) {
	$Folders{$folder->{'id'}} = $folder->{'name'};
    }

    my $n = 1;
    for my $entry (@{$decoded->{'items'}}) {
	my (%cmeta, @fieldlist, %address, %expiry);

	my $itype = find_card_type($entry);
	$cmeta{'title'} = $entry->{'name'} // 'Untitled';
	push @{$cmeta{'notes'}}, $entry->{'notes'};

	if ($entry->{'favorite'} == 1) {
	    push @{$cmeta{'tags'}}, 'Favorite';
	    $cmeta{'folder'}  = [ 'Favorite' ]				if $main::opts{'folders'};
	}
	if (exists $entry->{'folderId'} and defined $entry->{'folderId'}) {
	    push @{$cmeta{'tags'}}, $Folders{$entry->{'folderId'}};
	    push @{$cmeta{'folder'}}, $Folders{$entry->{'folderId'}}	if $main::opts{'folders'};
	}

	# Category specific fields
	my $subsection = $card_field_specs{$itype}{'textname'};
	for my $key (keys %{$entry->{$subsection}}) {
	    my $field = $entry->{$subsection}{$key};

	    if ($itype eq 'login') {
		if ($key eq 'uris') {
		    my @uris;
		    for (@{$entry->{$subsection}{'uris'}}) {
			if (not defined $_->{'match'} or $uri_match_types{$_->{'match'}}{'use'}) {
			    push @uris, $_->{'uri'};
			}
			else {
			    debug "URI match type '$uri_match_types{$_->{'match'}}{'name'}' unsupported - added to notes";
			    push @{$cmeta{'notes'}}, "uri($uri_match_types{$_->{'match'}}{'name'}): $_->{'uri'}";
			}
		    }
		    # First acceptable URI will be primary
		    if (@uris) {
			my $_ = shift @uris;
			push @fieldlist, [ uri => $_ ];
		    }
		    if (@uris) {
			push @fieldlist, [ 'additionalurls' => join "\n", @uris ];
		    }
		}
		else {
		    push @fieldlist, [ $key => $entry->{$subsection}{$key} ];
		}
	    }
	    elsif ($itype eq 'identity') {
		if ($key =~ /^(address[123]|city|state|postalCode|country)$/) {
		    my $outkey = $key eq 'postalCode' ? 'zip' : $key;
		    $address{$outkey} = $entry->{$subsection}{$key}	if $entry->{$subsection}{$key};
		}
		else {
		    push @fieldlist, [ $key => $entry->{$subsection}{$key} ];
		}
	    }
	    elsif ($itype eq 'note') {
		# nothing to do here
	    }
	    elsif ($itype eq 'creditcard') {
		if ($entry->{$subsection}{$key} and $entry->{$subsection}{$key} ne '') {
		    if ($key eq 'expYear' and $entry->{$subsection}{$key} =~ /^20\d{2}$/) {
			$expiry{'year'} = $entry->{$subsection}{$key};
		    }
		    elsif ($key eq 'expMonth') {
			$expiry{'month'} = sprintf "%02d", $entry->{$subsection}{$key};
		    }
		    else {
			push @fieldlist, [ $key => $entry->{$subsection}{$key} ];
		    }
		}
	    }
	    else {
		bail "Unexpected category '$itype'";
	    }
	}

	if (%expiry) {
	    if (exists $expiry{'year'} and exists $expiry{'month'}) {
		push @fieldlist, [ 'expiry' => $expiry{'year'} . $expiry{'month'} ];
	    }
	    else {
		push @fieldlist, [ 'expiration month' => $expiry{'month'} ]	if exists $expiry{'month'};
		push @fieldlist, [ 'expiration year'  => $expiry{'year'} ]	if exists $expiry{'year'};
	    }
	}

	if (%address) {
	    if (@address{qw/address1 address2 address3/}) {
		$address{'street'} = myjoin ', ', @address{qw/address1 address2 address3/};
		delete @address{qw/address1 address2 address3/};
	    }
	    push @fieldlist, [ 'ADDRESS' => \%address ];
	}

	# Custom fields
	my $fnum;
	for my $field (@{$entry->{'fields'}}) {
	    $fnum++;
	    my $label = $field->{'name'};
	    my $value = $field->{'value'};

	    $label ||= join "_", 'Unlabeled', $fnum;

	    #debug sprintf "%20s => %s\n",  $label, $value || '';
            next if not defined $value or $value eq '';

	    push @fieldlist, [ $label => $value ];
	}

	if (do_common($Cards, \@fieldlist, \%cmeta, $imptypes, $itype)) {
	    $n++;
	}
    }

    return $n;
}

sub do_common {
    my ($Cards, $fieldlist, $cmeta, $imptypes, $itype) = @_;

    # skip all types not specifically included in a supplied import types list
    return undef	if defined $imptypes and (! exists $imptypes->{$itype});

    my $normalized = normalize_card_data(\%card_field_specs, $itype, $fieldlist, $cmeta);
    my $cardlist   = explode_normalized($itype, $normalized);

    for (keys %$cardlist) {
	print_record($cardlist->{$_});
	push @{$Cards->{$_}}, $cardlist->{$_};
    }

    return 1;
}

sub do_export {
    add_custom_fields(\%card_field_specs);
    create_pif_file(@_);
}

sub find_card_type {
    my $entry = shift;
    my %types = (
	1 => 'login',
	2 => 'note',
	3 => 'creditcard',
	4 => 'identity',
    );

    return $types{$entry->{'type'}};
}

1;
