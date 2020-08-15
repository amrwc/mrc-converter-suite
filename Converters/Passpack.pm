# Passpack CSV export converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Passpack;

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

use IO::String;
# Force lib included CSV_PP for consistency
BEGIN { $ENV{PERL_TEXT_CSV}='Text::CSV_PP'; }
use Text::CSV qw/csv/;

=pod

=encoding utf8

=head1 Passpack converter module

=head2 Platforms

=over

=item B<macOS>: Initially tested with web version 7.7.14

=item B<Windows>: Initially tested with web version 7.7.14

=back

=head2 Description

Converts your exported Passpack data to 1PIF for 1Password import.

=head2 Instructions

Launch Passpack.

Launch your browser and unlock your Passpack vault.
From the Passpack toolbar menu, select C<Tools>, and on the next screen, select C<Export>.
Select the option C<Comma Separated Values> and the other option C<All entries>.
Select the columns to export under C<Click on the name of the first field to export>.
Select these one at a time I<in the same order> that they are presented on the screen: 
B<Name>, B<User ID>, B<Password>, B<Link>, B<Tags>, B<Notes> and B<Email>.
Click the C<Continue> button.
A new window will appear with your exported data.
Select all of the text data in the text box and copy it.
You will save this copied data with either B<TextEdit> (on macOS) or B<Notepad> (on Windows) as follows:

B<macOS>: Open TextEdit, and select its C<< TextEdit > Preferences >> menu.
In the C<New Document> tab, under C<Format>, select C<Plain Text> and close that dialog.
Open a new document (⌘ + N).
Paste your copied data (⌘ + V), and save the document to your B<Desktop> with the file name B<pm_export.txt>,
selecting C<Unicode (UTF-8)> as the C<Plain Text Encoding>.

B<Windows>: Create and open a new text document by right-clicking the Desktop and selecting C<< New > Text Document >>.
Name the document B<pm_export.txt>.
Right-click that document, select C<Edit>, and paste your copied data (Ctrl-V).
Select Notepad's C<< File > Save As... >> menu, set the C<Encoding> to C<UTF-8>, and click C<Save> to save the document.

You may now quit Passpack.

=head2 Notes

This converter supports cross-platform conversion (the export may be exported on one platform, but converted on another).

=cut

my %card_field_specs = (
    login =>			{ textname => '', fields => [
	[ 'title',		0, qr/^title$/, ],
	[ 'username',		0, qr/^username$/, ],
	[ 'password',		0, qr/^password$/, ],
	[ 'url',		0, qr/^url$/, ],
	[ 'notes',		0, qr/^notes$/, ],
	[ 'email',		0, qr/^email$/,		{ custfield => [ 'other.Other Information', $Utils::PIF::k_string, 'email' ] } ],
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

    my $csv = Text::CSV->new ({
	    binary => 1,
	    #allow_loose_quotes => 1,
	    sep_char => ",",
	    eol => "\n",
    });

    my $data = slurp_file($file, 'utf8');
    $data =~ s/\A\N{BOM}//;					# remove BOM
    my $io = IO::String->new($data);

    my %Cards;
    my ($n, $rownum) = (1, 1);

    $csv->column_names(qw/title username password url tags notes email/);
    while (my $row = $csv->getline_hr($io)) {
	debug 'ROW: ', $rownum++;

	my $itype = find_card_type($row);

	next if defined $imptypes and (! exists $imptypes->{$itype});

	my (%cmeta, @fieldlist);
	# Grab the special fields and delete them from the row
	@cmeta{qw/title notes tags/} = @$row{qw/title notes tags/};
	delete @$row{qw/title notes tags/};

	# Everything that remains in the row is the field data
	for (keys %$row) {
	    debug "\tcust field: $_ => $row->{$_}";
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
    my $hr = shift;
    my $type = ($hr->{'url'} ne '' or $hr->{'username'} ne '' or $hr->{'password'} ne '') ? 'login' : 'note';
    debug "type detected as '$type'";
    return $type;
}

1;
