# Data Guardian CSV export converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Dataguardian;

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

use Time::Local qw(timelocal);
use Time::Piece;
# Force lib included CSV_PP for consistency
BEGIN { $ENV{PERL_TEXT_CSV}='Text::CSV_PP'; }
use Text::CSV qw/csv/;

=pod

=encoding utf8

=head1 Data Guardian converter module

=head2 Platforms

=over

=item B<macOS>: Initially tested with version 3.2

=item B<Windows>: Initially tested with version 3.2

=back

=head2 Description

Converts your exported Data Guardian data to 1PIF for 1Password import.

=head2 Instructions

Launch Data Guardian.

Export its database to a CSV text file using the C<Record E<gt> Export...> menu item.
From the left side bar, select B<Text>.
Under the list of fields that can be exported, click the C<Check All> button.
In the C<Field Delimiter> pulldown, select the C<Comma (CSV)> choice.
Under C<Options>, select the C<Include header row> checkbox.
Click the C<Export> button, and when the C<Export Database> dialog appears, navigate to your Desktop folder.
Save the file to your B<Desktop> folder with a simple name such as B<pm_export.txt>.
When the dialog appears asking which suffix to use, select the C<use .txt> button.

You may now quit Data Guardian.

=head2 Notes

Data Guardian does not construct a reliable CSV file.
In certain cases, it is impossible to determine one field from the next field (the field's
value will contain one or more (unescaped) commas and/or double quotes).
When this occurs, the converter will skip the record, and report an error indicating the name of the record.

This converter supports cross-platform conversion (the export may be exported on one platform, but converted on another).

=cut

# fields to be ignored from the CSV output
my @ignored_fields = (
    'File Count',
    'Date Synchronized',
    'Time Synchronized',
    'Date and Time Synchronized',
    # these are superfluous because they are combined into the fields (e.g. 'Date and Time Created')
    'Date Created',
    'Time Created',
    'Date Modified',
    'Time Modified',
);

my %card_field_specs = (
    blankrecord =>		{ textname => '', type_out => 'note', fields => [
    ]},
    contact =>			{ textname => '', type_out => 'note', fields => [
	[ '_homephone',		1, qr/^Home Phone$/, ],
	[ '_workphone',		1, qr/^Work Phone$/, ],
	[ '_email',		1, qr/^E-Mail$/, ],
	[ '_homepage',		1, qr/^Homepage$/, ],
	[ '_birthday',		1, qr/^Birthday$/, ],
	[ '_address',		1, qr/^Address$/, ],
    ]},
    license =>			{ textname => '', type_out => 'software', fields => [
	[ 'product_version',	1, qr/^Version$/, ],
	[ 'reg_name',		1, qr/^User Name$/, ],
	[ 'reg_email',		1, qr/^User E-Mail$/, ],
	[ 'order_number',	1, qr/^Txn\. Number$/, ],
	[ '_order_date',	1, qr/^Txn\. Date$/,	{ custfield => [ $Utils::PIF::sn_order, $Utils::PIF::k_string, 'order date' ] } ],
	[ 'reg_code',		1, qr/^License Code$/, ],
	[ 'publisher_website',	1, qr/^Dev\. URL$/, ],
	[ '_dev_phone',		1, qr/^Dev\. Phone$/,	{ custfield => [ $Utils::PIF::sn_publisher, $Utils::PIF::k_string, 'phone #' ] } ],
	[ 'support_email',	1, qr/^Dev\. E-Mail$/, ],
    ]},
    recipe =>			{ textname => '', type_out => 'note', fields => [
	[ '_servings',		1, qr/^Servings$/, ],
	[ '_lastbaked',		1, qr/^Last Baked$/, ],
	[ '_instuctions',	1, qr/^Instructions$/, ],
	[ '_ingredients',	1, qr/^Ingredients$/, ],
	[ '_credit',		1, qr/^Credit$/, ],
	[ '_cooktime',		1, qr/^Cook Time$/, ],
    ]},
    site =>			{ textname => '', type_out => 'login', fields => [
	[ 'url',		1, qr/^URL$/, ],
	[ 'username',		1, qr/^Login$/, ],
	[ 'password',		1, qr/^Password$/, ],
    ]},
    note =>			{ textname => '', fields => [
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
    }
}

sub do_import {
    my ($file, $imptypes) = @_;

    my $parsed;
    my @column_names;
    eval { $parsed = csv(
	    in => $file,
	    allow_loose_quotes => 1,
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
	for my $label (keys %$row) {
	    next if ($row->{$label} ne '' and ! grep { $label eq $_ } @ignored_fields);
	    delete $row->{$label};
	}

	my $itype = find_card_type($row);

	next if defined $imptypes and (! exists $imptypes->{$itype});

	my %cmeta;
	# Grab the special fields and delete them from the row
	$cmeta{'title'} = $row->{'Name'} // 'Unnamed';	delete $row->{'Name'};
	for (qw/Note Notes/) {
	    next if not exists $row->{$_};
	    $cmeta{'notes'} .= "\n"	if length $cmeta{'notes'};
	    $cmeta{'notes'} .= $row->{$_};
	    delete $row->{$_};
	}

	my @card_tags;
	for (qw/Private Locked/) {
	    next if not exists $row->{$_};
	    push @{$cmeta{'tags'}}, $_		if $row->{$_} eq 'Yes';
	    delete $row->{$_};
	}

	$row->{'Date Modified'} = $row->{'Date and Time Modified'};	delete $row->{'Date and Time Modified'};
	$row->{'Date Created'}  = $row->{'Date and Time Created'};	delete $row->{'Date and Time Created'};
	unless ($main::opts{'notimestamps'}) {
	    $cmeta{'modified'} = date2epoch($row->{'Date Modified'});
	    $cmeta{'created'}  = date2epoch($row->{'Date Created'});
	    delete $row->{'Date Modified'};
	    delete $row->{'Date Created'};
	}

	my @fieldlist;
	# Everything that remains in the row is the field data
	for (sort by_field_name keys %$row) {
	    debug "\tfield: $_ => $row->{$_}";
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
    my $f = shift;

    my $type = 'note';
    for my $type (sort by_test_order keys %card_field_specs) {
	for my $cfs (@{$card_field_specs{$type}{'fields'}}) {
	    for (keys %$f) {
		if ($cfs->[CFS_TYPEHINT] and $_ =~ $cfs->[CFS_MATCHSTR]) {
		    debug "type detected as '$type' (key='$_')";
		    return $type;
		}
	    }
	}
    }

    #my $type = grep($_ =~ /^Address|Username|Password$/, @$labels) ? 'login' : 'note';
    debug "\t\ttype defaulting to '$type'";
    return $type;
}

# sort logins as the last to check
sub by_test_order {
    return  1 if $a eq 'login';
    return -1 if $b eq 'login';
    $a cmp $b;
}

# sort field data, moving Date Created and Date Modified to the end of the list
sub by_field_name {
    return  1 if $a eq 'Date Modified';
    return -1 if $b eq 'Date Modified';
    return  1 if $a eq 'Date Created';
    return -1 if $b eq 'Date Created';
    $a cmp $b;
}

#Date and Time Modified: Saturday, April 11, 2015 8:20:59 PM
#Date and Time Created: Saturday, April 11, 2015 8:19:39 PM
# Date converters
# lastmod field:	 yyyy-mm-ddThh:mm:ss
sub parse_date_string {
    local $_ = $_[0];
    my $when = $_[1] || 0;					# -1 = past only, 0 = assume this century, 1 = future only, 2 = 50-yr moving window

    if (my $t = Time::Piece->strptime($_, "%A, %B %d, %Y %H:%M:%S %p")) {
	return $t;
    }

    return undef;
}

sub date2epoch {
    my $t = parse_date_string @_;
    return undef if not defined $t;
    return defined $t->year ? 0 + timelocal($t->sec, $t->minute, $t->hour, $t->mday, $t->mon - 1, $t->year): $_[0];
}

1;
