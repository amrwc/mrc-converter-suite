# EssentialPIM CSV export converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Essentialpim;

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

=head1 EssentialPIM converter module

=head2 Platforms

=over

=item B<macOS>: N/A

=item B<Windows>: Initially tested with version 6.04

=back

=head2 Description

Converts your exported EssentialPIM data to 1PIF for 1Password import.

=head2 Instructions

Launch EssentialPIM and export its password database to a text file using
the C<File E<gt> Export E<gt> Password Entries E<gt> Comma Separated Values (*.csv)...> menu.
Select All entries from the C<Entries to be exported> dialog.
Optionally, you may select the fields you want exported by selecting the C<Fields...> button (however, you should keep selected
the fields that correspond to the stock fields: B<Title>, B<User Name>, B<Password>, B<URL>, and B<Notes>).
Click the C<OK> button, and navigate to your B<Desktop> folder, and save the file with the name B<pm_export.txt>.

You may now quit EssentialPIM.

=head2 Notes

EssentialPIM does I<not> properly handle the exported field names when the names contain any comma characters.
Before you export, edit a single password entry record in EssentialPIM, and examine each of your field names.
Replace all commas in the field names with some other character.
Editing the field names inside a single record will globally change the field names for all records.
Once the commas are removed from the field names, you may export your data safely.

=cut

my %card_field_specs = (
    password =>			{ textname => '', type_out => 'login', fields => [
	[ 'title',		0, qr/^Title$/, ],
	[ 'username',		1, qr/^User Name$/, ],
	[ 'password',		1, qr/^Password$/, ],
	[ 'url',		1, qr/^URL$/, ],
	[ 'notes',		0, qr/^Notes$/, ],
    ]},
    note =>			{ textname => 'Note', fields => [
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

    my $csv = Text::CSV->new ({
	    binary => 1,
	    allow_loose_quotes => 1,
	    sep_char => ',',
	    eol => ",\n",
    });

    open my $io, "<:encoding(utf8)", $file
	or bail "Unable to open CSV file: $file\n$!";

    # remove BOM
    my $bom;
    (my $nb = read($io, $bom, 1) == 1 and $bom eq "\x{FEFF}") or
	bail "Failed to read BOM from CSV file: $file\n$!";

    my $column_names = $csv->getline($io) or
	bail "Failed to parse CSV column names: $!";

    # get the card type, and create a hash of the key field names that maps the column names to column positions
    my ($itype, $card_names_to_pos) = find_card_type($column_names);
    %$card_names_to_pos or
	bail "CSV column names do not match expected names";

    # grab and remove the special field column names
    for (sort { $b <=> $a } values %$card_names_to_pos) {
	splice @$column_names, $_, 1;
    }

    my %Cards;
    my ($n, $rownum) = (1, 1);

    while (my $row = $csv->getline($io)) {
	debug 'ROW: ', $rownum++;
	next if defined $imptypes and (! exists $imptypes->{$itype});

	my (@fieldlist, %cmeta);
	# save the special fields to pass to normalize_card_data below, and then remove them from the row.
	for (keys %$card_names_to_pos) {
	    $cmeta{$_} = $row->[$card_names_to_pos->{$_}];
	}
	# remove the special field values
	for (sort { $b <=> $a } values %$card_names_to_pos) {
	    splice @$row, $_, 1;
	}

	# everything that remains in the row is the field data
	for (my $i = 0; $i <= $#$column_names; $i++) {
	    debug "\tcust field: $column_names->[$i] => $row->[$i]";
	    push @fieldlist, [ $column_names->[$i] => $row->[$i] ];		# retain field order
	}

	my $normalized = normalize_card_data(\%card_field_specs, $itype, \@fieldlist, \%cmeta);
	my $cardlist   = explode_normalized($itype, $normalized);

	for (keys %$cardlist) {
	    print_record($cardlist->{$_});
	    push @{$Cards{$_}}, $cardlist->{$_};
	}
	$n++;
    }
    if (! $csv->eof()) {
	warn "Unexpected failure parsing CSV: row $n";
    }

    summarize_import('item', $n - 1);
    return \%Cards;
}

sub do_export {
    add_custom_fields(\%card_field_specs);
    create_pif_file(@_);
}

sub find_card_type {
    my $row = shift;
    my $otype = 'note';
    my %col_names_to_pos;

    for my $type (keys %card_field_specs) {
	for my $cfs (@{$card_field_specs{$type}{'fields'}}) {
	    for (my $i = 0; $i <= $#$row; $i++) {
		if (defined $cfs->[CFS_MATCHSTR] and $row->[$i] =~ /$cfs->[CFS_MATCHSTR]/ms) {
		    $otype = $type	 			if $cfs->[CFS_TYPEHINT];
		    $col_names_to_pos{$cfs->[CFS_FIELD]} = $i	if $cfs->[CFS_FIELD] =~ /^title|notes$/;
		}
	    }
	}
    }

    debug "\t\ttype detected as '$otype'";
    return ($otype, \%col_names_to_pos);
}

1;
