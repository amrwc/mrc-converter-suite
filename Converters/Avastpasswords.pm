# Avast Passwords JSON export converter
#
# Copyright 2020 Mike Cappella (mike@cappella.us)

package Converters::Avastpasswords;

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
use Time::Piece;

=pod

=encoding utf8

=head1 Avast Passwords converter module

=head2 Platforms

=over

=item B<macOS>:  Initially tested with version 4.6.6.4372

=item B<Windows>: Not yet tested

=back

=head2 Description

Converts your exported Avast Passwords JSON data to 1PIF for 1Password import.

=head2 Instructions

Launch the desktop version of Avast Passwords.
You will export your Avast Passwords data as B<JSON> data.

Under the C<Avast Passwords E<gt> Import / Export> menu, select the C<Export to JSON...> menu item.
When the C<Export passwords to JSON> dialog appears, navigate to your Desktop folder,
and save the file with the name B<pm_export.json> to your Desktop.
Click C<OK> when the confirmation dialog appears.

You may now quit Avast Passwords.

=cut

my %card_field_specs = (
    creditcard =>		{ textname => 'cards', fields => [
	[ 'cardholder',		0, qr/^holderName$/, ],
	[ 'type',		0, qr/^brand$/, ],
	[ 'ccnum',		0, qr/^cardNumber$/, ],
	[ 'expiry',		0, qr/^expiry$/, ],
	[ 'cvv',		0, qr/^cvv$/, ],
	[ 'pin',		0, qr/^pin$/, ],
	[ 'expiry',		0, qr/^expirationDate$/, 	{ func => sub { return date2monthYear($_[0]) } } ],

    ]},
    login =>			{ textname => 'logins', fields => [
	[ 'username',		0, qr/^loginName$/, ],
	[ 'password',		0, qr/^pwd$/, ],
	[ 'url',		0, qr/^url$/, ],
	[ '_color',		0, qr/^color$/, ],

    ]},
    password =>			{ textname => 'password', fields => [
	[ 'password',		0, qr/^pwd$/, ],
    ]},
    note =>			{ textname => 'notes', fields => [
	[ '_color',		0, qr/^color$/, ],
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

    my $decoded = decode_json Encode::encode('UTF-8', $$data);

    my %titlekey_by_type = (
	notes		=> 'label',
	cards		=> 'custName',
	logins		=> 'custName',
    );

    my $n = 1;
    for my $type (keys %$decoded) {
	my $itype = find_card_type($type);
	debug 'Processing type: ', $itype;

	for my $entry (@{$decoded->{$type}}) {
	    my (%cmeta, @fieldlist, $demoted_itype);

	    $cmeta{'title'} = $entry->{$titlekey_by_type{$type}} // 'Untitled';
	    delete $entry->{$titlekey_by_type{$type}};

	    my $noteskey = $type eq 'notes' ? 'text' : 'note';
	    push @{$cmeta{'notes'}}, $entry->{$noteskey};
	    delete $entry->{$noteskey};

	    # convert a login entry with no url nor login name to 'password' entry
	    if ($itype eq 'login' and $entry->{'url'} eq '' and $entry->{'loginName'} eq '') {
		debug '  login entry demoted to password: ', $cmeta{'title'};
		$demoted_itype = 'password';
	    }

	    if (exists $entry->{'color'}) {
		push @{$cmeta{'tags'}}, 'Color ' . $entry->{'color'};
		delete $entry->{'color'};
	    }

	    # Category specific fields
	    for my $field (%$entry) {
		push @fieldlist, [ $field => $entry->{$field} ]		if defined $entry->{$field} and $entry->{$field} ne '';
	    }

	    if (do_common($Cards, \@fieldlist, \%cmeta, $imptypes, $demoted_itype // $itype)) {
		$n++;
	    }
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
    my $type = shift;

    for my $key (keys %card_field_specs) {
	return $key	if $card_field_specs{$key}{'textname'} eq $type;
    }

    return 'note';
}

#  "expirationDate" : {
#      "day"   : 1,
#      "month" : 12,
#      "year"  : 2023
#  },
sub parse_date_string {
    local $_ = $_[0];

    my ($m,$d,$y) = ($_->{'month'}, $_->{'day'}, $_->{'year'});
    return undef unless $m and $y;

    $m = '0' . $m	if length $m eq 1;
    $d = '0' . $d	if length $d eq 1;
    if (my $t = Time::Piece->strptime(join('-', $y, $m, $d), "%Y-%m-%d")) {
	return $t;
    }

    return undef;
}

sub date2monthYear {
    my $t = parse_date_string(@_);
    return defined $t && defined $t->year ? sprintf("%d%02d", $t->year, $t->mon) : '';
}
1;
