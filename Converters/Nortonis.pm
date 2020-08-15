# Norton Identity Safe CSV export converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Nortonis;

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

# Force lib included CSV_PP for consistency
BEGIN { $ENV{PERL_TEXT_CSV}='Text::CSV_PP'; }
use Text::CSV qw/csv/;

=pod

=encoding utf8

=head1 Norton Identity Safe converter module

=head2 Platforms

=over

=item B<macOS>: Untested (see Notes)

=item B<Windows>: Initially tested with version 2014.7.11.42

=back

=head2 Description

Converts your exported Norton Identity Safe data to 1PIF for 1Password import.

=head2 Instructions

Launch Norton Identity Safe.

Export its database as a CSV export file using the Settings (gear) icon, and selecting the C<Import/Export> tab.
Select the C<Plain Text - CSV file (Logins and Notes only)> radio button, and click C<Export>.
Enter your vault password when the C<Password Protected Item> dialog appears, and click C<OK>.
Navigate to your B<Desktop> folder in the C<Save As> dialog.
In the C<File name> area, enter the name B<pm_export.csv>, and click C<Save>.
Click C<OK> when the successful export dialog appears.

You may now quit Norton Identity Safe.

=head2 Notes

B<macOS>: Norton Identity Safe exports on macOS have not been untested - a trial version of the software was unavailable.
It should work, but please report your results.

Norton Identity Safe does not export the Wallet items Credit Card, Bank Account, or Identity.
It only exports Login and Note items.

Norton Identity Safe does not export Tags.

This converter supports cross-platform conversion (the export may be exported on one platform, but converted on another).

=cut

my %card_field_specs = (
    login =>			{ textname => '', fields => [
	[ 'url',		0, qr/^url$/, ],
	[ 'username',		0, qr/^username$/, ],
	[ 'password',		0, qr/^password$/, ],
	[ 'title',		0, qr/^title$/, ],
	[ '_grouping',		0, qr/^grouping$/, ],
	[ '_extra',		0, qr/^extra$/, ],
    ]},
    note =>			{ textname => '', fields => [
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [],
    }
}

sub do_import {
    my ($file, $imptypes) = @_;

    my $parsed;
    my @column_names;
    eval { $parsed = csv(
	    in => $file,
	    auto_diag => 1,
	    diag_verbose => 1,
	    detect_bom => 1,
	    sep_char => ",",
	    munge_column_names => sub { $_ },		# dont lc headers
	    keep_headers => \@column_names,
	);
    };
    $parsed or
	bail "Failed to parse file: $file";

    my %Cards;
    my ($n, $rownum) = (1, 1);
    while (my $row = shift @$parsed) {
	debug 'ROW: ', $rownum++;

	my $itype = find_card_type($row);

	next if defined $imptypes and (! exists $imptypes->{$itype});

	# Grab the special fields and delete them from the row
	my %cmeta;
	@cmeta{qw/title notes tags/} = @$row{qw/name extra grouping/};
	delete @$row{qw/name extra grouping/};

	my @fieldlist;
	# Everything that remains in the row is the field data
	for (keys %$row) {
	    debug "\tcust field: $_ => $row->{$_}";
	    if ($itype eq 'note' and $row->{'url'} eq 'http://sn') {
		$row->{'url'} = '';
	    }
	    push @fieldlist, [ $_ => $row->{$_} ];
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
    my $hr = shift;
    my $type = 'note';
    if ($hr->{'url'} ne 'http://sn') {
	for (qw /username password/) {
	    if (defined $hr->{$_} and $hr->{$_} ne '') {
		$type = 'login';
		last;
	    }
	}
    }

    debug "type detected as '$type'";
    return $type;
}

1;
