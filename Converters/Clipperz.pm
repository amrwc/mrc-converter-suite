# Clipperz JSON export converter
#
# Copyright 2014 Mike Cappella (mike@cappella.us)

package Converters::Clipperz;

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

use JSON::PP;
use HTML::Entities;

=pod

=encoding utf8

=head1 Clipperz converter module

=head2 Platforms

=over

=item B<macOS>: Clipperz is a web program, and has no version numbers; initially tested on Sept 2014

=item B<Windows>: Clipperz is a web program, and has no version numbers; initially tested on Sept 2014

=back

=head2 Description

Converts your exported Clipperz data to 1PIF for 1Password import.

=head2 Instructions

Log into L<Clipperz|https://clipperz.is/app/> to export your database.

When logged in, select the menu button in the upper right of the interface (the 3 stacked bars). Select C<Data>, then select C<Export>,
and then click the C<download HTML+JSON> button on the left.

Some browsers such as Firefox or Internet Explorer may ask what to do with the file.
You want to B<Save> the file - in Firefox, for example, click the C<Save File> selector and then click C<OK>.
Other browsers may immediately save the file to your browser's Downloads folder.

The downloaded file will be named something like I<20190115-Clipperz_Export.html>.
Move this file to your Desktop. That will be the file name you supply to the converter (you may rename it).

You may now logoff the Clipperz site.

=head2 Notes

The Clipperz converter supports only English field names.

=cut


my %card_field_specs = (
    bankacct =>                 { textname => undef, fields => [
	[ 'bankName',		0, qr/^Bank$/, 				{ to_title => 'value' } ],
	[ 'accountNo',		0, qr/^Account number$/, ],
	[ 'url',		1, qr/^Bank website$/,			{ type_out => 'login' } ],
	[ 'username',		1, qr/^Online banking ID$/,		{ type_out => 'login' } ],
	[ 'password',		1, qr/^Online banking password$/,	{ type_out => 'login' } ],
    ]},
    login =>                    { textname => undef, fields => [
        [ 'url',		1, qr/^Web address$/, ],
        [ 'username',		1, qr/^Username or email$/, ],
        [ 'password',		1, qr/^Password$/, ],
    ]},
    creditcard =>               { textname => undef, fields => [
        [ 'type',		1, qr/^Type /, 				{ to_title => 'value' } ],
        [ 'ccnum',		0, qr/^Number$/, ],
        [ 'cardholder',		1, qr/^Owner name$/, ],
        [ '_expires',		1, qr/^Expiry date$/, ],
        [ 'cvv',		1, qr/^CVV2$/, ],
        [ 'pin',		0, qr/^PIN$/, ],
        [ 'url',		1, qr/^Card website$/, 			{ type_out => 'login' }],
        [ 'username',		0, qr/^Username$/, 			{ type_out => 'login' }],
        [ 'password',		0, qr/^Password$/, 			{ type_out => 'login' }],
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [],
    };
}

sub do_import {
    my ($file, $imptypes) = @_;
    my %Cards;

    $_ = slurp_file($file);
    if (/<textarea>(.+?)<\/textarea>/) {
	$_ = decode_entities $1;
    }

    s/^\x{ef}\x{bb}\x{bf}//	if $^O eq 'MSWin32';		# remove BOM
    my $decoded = decode_json $_;

    my $n = 1;
    for my $entry (@$decoded) {
	my (%cmeta, @fieldlist);
	my $itype = find_card_type($entry->{'currentVersion'}{'fields'});

	# skip all types not specifically included in a supplied import types list
	next if defined $imptypes and (! exists $imptypes->{$itype});

	$cmeta{'title'} = $entry->{'label'};
	$cmeta{'notes'} = $entry->{'data'}{'notes'};

	for my $key (keys %{$entry->{'currentVersion'}{'fields'}}) {
	    my ($label, $value) = ( @{$entry->{'currentVersion'}{'fields'}{$key}}{'label','value'} );
	    next if not defined $value or $value eq '';
	    push @fieldlist, [ $label => $value ];		# @fieldlist maintains card's field order
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

sub find_card_type {
    my $f = shift;

    for my $type (sort by_test_order keys %card_field_specs) {
	for my $cfs (@{$card_field_specs{$type}{'fields'}}) {
	    for (keys %$f) {
		if ($cfs->[CFS_TYPEHINT] and $f->{$_}{'label'} =~ $cfs->[CFS_MATCHSTR]) {
		    debug "type detected as '$type' (key='$f->{$_}{'label'}')";
		    return $type;
		}
	    }
	}
    }

    debug "\t\ttype defaulting to 'note'";
    return 'note';
}

# sort logins as the last to check
sub by_test_order {
    return  1 if $a eq 'login';
    return -1 if $b eq 'login';
    $a cmp $b;
}

1;
