# Generic CSV converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Csv;

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
use Time::Piece;
use Time::Local qw(timelocal);

=pod

=encoding utf8

=head1 CSV converter module

=head2 Platforms

=over

=item B<macOS>: Supported

=item B<Windows>: Supported

=back

=head2 Description

The B<csv> converter is a generic CSV/TSV (comma or tab separated values) converter that supports conversion to from CSV/TSV to 1PIF,
for the following 1Password categories:

=over

=item Bank Account

=item Credit Card

=item Identity

=item Login

=item Membership

=item Password

=item Social Security

=item Software License

=back

The converter defaults to CSV.
If your file is in a TSV (or other separated-values) format, you can specify the separator character on the command line using
the C<< --sepchar >> option with a I<char> argument.
The I<char> argument can be C<\t> or the case-insensitive word B<tab> (e.g. C<--sepchar tab>).
Other characters are supported, but not double-quotes.

=head2 Instructions

Format your file such that it contains only a single category of data per file.
The category types are listed above.

Construct the file using a I<spreadsheet> program.
It is not a good idea to use a text editor to manually construct a CSV/TSV file, unless you clearly understand CSV/TSV
formatting and quoting rules, and file encodings.

The first row of the data I<must> be the header row, and it I<must> contain specifically named field labels.
These are used to inform the converter about the data contained in the column, and to identify the target 1Password category.
The names for the field label are indicated in the table below.
Those shown in B<bold> trigger category detection - you need at least one of these.
Additional per-category notes and requirements are listed in the table.

=over

=item Labels are case-insensitive.

=item The order of the columns in your file is irrelevant.

=item You may supply additional columns with your own custom labels.

=item You B<must> include at least one of the field labels shown in bold in the table below.

=item The converter will detect the file's encoding, when it contains a BOM (byte order mark).
Valid encodings are: UTF-8, UTF-16BE, UTF-16LE, UTF-32BE, and UTF-32LE.
If there is no BOM, UTF-8 or ASCII is assumed.

=back

=begin :text

Note: The table mentioned above is in the README file - see it for details.

=end :text

=begin markdown

| Category | Field Labels<br />*Labels in bold trigger category detection* | Notes  |
| :----------------|:---------|:-------|
| **Bank Account** | *Title*, **Bank Name**, **Owner**, **Account Type**, **Routing Number**, **Account Number**, **SWIFT**, **IBAN**, *PIN*, *Phone*, *Address*, *Notes* | See Notes 1,2 regarding Account Type. |
| **Credit Card** | *Title*, **Card Number**, **Expires**, **Cardholder**, *PIN*, **Bank**, **CVV**, *Notes* | See Notes 1,3 regarding Expires. |
| **Identity** | *Title*, **First Name**, **Initial**, **Last Name**, **Sex**, **Birth Date**, **Occupation**, *Company*, **Department**, **Job Title**, **Address**, **Default Phone**, **Home Phone**, **Cell Phone**, **Business Phone**, **Default Username**, **Reminder Question**, **Reminder Answer**, **Email**, *Website*, **ICQ**, **Skype**, **AIM**, **Yahoo**, **MSN**, **Forum Signature**, *Notes* | See Note 6 regarding Address |
| **Login** | *Title*, **Login Username**, **Login Password**, **Login URL**, **Additional URLs**, *Notes* | See Note 7 regarding Additional URLs |
| **Membership** | *Title*, **Group**, **Member Name**, **Member ID**, **Expiration Date**, **Member Since**, *PIN*,  *Telephone*,  **Membership Username**,  **Membership Password**, **Membership URL**, *Notes* | See Notes 1,3 regarding Expiration Date and Member Since.<br />See Note 5 regarding Membership Username, Membership Password and Membership URL. |
| **Password** | *Title*, **Password URL**, **Password**, *Notes* | |
| **Social Security** | *Title*, *Name*, **SS Number**, *Notes* | |
| **Software** | *Title*, **Version**, **License Key**, **Licensed To**, **Registered Email**, *Company*, **Download Link**, **Software Publisher**, **Publisher's Website**, **Retail Price**, **Support Email**, **Purchase Date**, **Order Number**, *Notes* | See Notes 1,4 regarding Purchase Date. |
| **Note 1**: Invalid values will go to the Notes section of the entry.<br />**Note 2**: Valid values for Account Type are: **Checking**, **Savings**, **LOC** or **Line of Credit**, **ATM**, **Money Market** or **MM**, or **Other** (case-insensitive).<br />**Note 3**: Valid dates are in the format mm/yyyy or mmyyyy.<br />**Note 4**: Date is a Unix epoch date (seconds since 1/1/1970).<br />**Note 5**: These fields will be split from the item and placed into a 1Password Login item.<br />**Note 6**: An Address will go to the Notes section of the entry, since arbitrary address data cannot be reliably parsed into 1Password's required internal form.<br />**Note 7**: Additional URLs is a semcolon- or newline-separated list of URLs - these will be added as supplementary (i.e. clickable, open and fill) URLs in the Login item. |||
[ Table of Field Labels per 1Password Category ]

=end markdown
        
=head2 Additional Columns

There are a few additional reserved field label names: B<Tags>, B<Modified>, and B<Created>.
These will be treated specially.

Data in the B<Tags> column will be used to set the 1Password item's B<Tag> value.
Multiple tags may be assigned using a comma-separated list of values.

The columns B<Modified> and/or B<Created> will be used to set the item's modified and created dates, respectively.
The values are Unix epoch integers (seconds since 1/1/1970).
Invalid values will cause the data to be stored in the item's Notes area.

You may have additional columns.
The labels you've supplied will be used to create custom fields in the 1Password item.
Do not use any of the reserved field labels mentioned elsewhere.

This converter supports cross-platform conversion (the export may be exported on one platform, but converted on another).

=cut

my %card_field_specs = (
    bankacct =>			{ textname => '', fields => [
	[ 'bankName',		1, qr/^Bank Name$/i, ],
	[ 'owner',		1, qr/^Owner$/i, ],
	[ 'accountType',	1, qr/^Account Type$/i, ],
	[ 'routingNo',		1, qr/^Routing Number$/i, ],
	[ 'accountNo',		1, qr/^Account Number$/i, ],
	[ 'swift',		1, qr/^SWIFT$/i, ],
	[ 'iban',		1, qr/^IBAN$/i, ],
	[ 'telephonePin',	0, qr/^PIN$/i, ],
	[ 'branchPhone',	0, qr/^Phone$/i, ],
	[ 'branchAddress',	0, qr/^Address$/i, ],
    ]},
    creditcard =>		{ textname => '', fields => [
	[ 'ccnum',		1, qr/^Card Number$/i, ],
	[ 'expiry',		1, qr/^Expires$/i, 		{ func => sub { return date2monthYear($_[0]) } } ],
	[ 'cardholder',		1, qr/^Cardholder$/i, ],
	[ 'pin',		0, qr/^PIN$/i, ],
	[ 'bank',		1, qr/^Bank$/i, ],
	[ 'cvv',		1, qr/^CVV$/i, ],
    ]},
    identity =>			{ textname => '', fields => [
	[ 'firstname',		1, qr/^First Name$/i, ],
	[ 'initial',		1, qr/^Initial$/i, ],
	[ 'lastname',		1, qr/^Last Name$/i, ],
	[ 'sex',		1, qr/^Sex$/i, ],
	[ 'birthdate',		1, qr/^Birth Date$/i,		{ func => sub { return date2epoch($_[0]) } } ],
	[ 'occupation',		1, qr/^Occupation$/i, ],
	[ 'company',		0, qr/^Company$/i, ],
	[ 'department',		1, qr/^Department$/i, ],
	[ 'jobtitle',		1, qr/^Job Title$/i, ],
	[ '_address',		1, qr/^Address$/i, ],
	[ 'defphone',		1, qr/^Default Phone$/i, ],
	[ 'homephone',		1, qr/^Home Phone$/i, ],
	[ 'cellphone',		1, qr/^Cell Phone$/i, ],
	[ 'busphone',		1, qr/^Business Phone$/i, ],
	[ 'username',		1, qr/^Default Username$/i, ],
	[ 'reminderq',		1, qr/^Reminder Question$/i, ],
	[ 'remindera',		1, qr/^Reminder Answer$/i, ],
	[ 'email',		1, qr/^Email$/i, ],
	[ 'website',		0, qr/^Website$/i, ],
	[ 'icq',		1, qr/^ICQ$/i, ],
	[ 'skype',		1, qr/^Skype$/i, ],
	[ 'aim',		1, qr/^AIM$/i, ],
	[ 'yahoo',		1, qr/^Yahoo$/i, ],
	[ 'msn',		1, qr/^MSN$/i, ],
	[ 'forumsig',		1, qr/^Forum Signature$/i, ],
    ]},
    login =>			{ textname => '', fields => [
	[ 'url',		1, qr/^login url$/i, ],
	[ 'username',		1, qr/^login username$/i, ],
	[ 'password',		1, qr/^login password$/i, ],
	[ '*additionalurls',	1, qr/^additional urls$/i, ],	# *additionalurls: this is a PIF.pm special key
    ]},
    membership =>		{ textname => '', fields => [
	[ 'org_name',		1, qr/^group$/i, ],
	[ 'member_name',	1, qr/^member name$/i, ],
	[ 'membership_no',	1, qr/^member id$/i, ],
	[ 'expiry_date',	1, qr/^expiration date$/i,	{ func => sub { return date2monthYear($_[0]) } } ],
	[ 'member_since',	1, qr/^member since$/i,		{ func => sub { return date2monthYear($_[0]) } } ],
	[ 'pin',		0, qr/^pin$/i, ],
	[ 'phone',		0, qr/^telephone$/i, ],
	[ 'username',		1, qr/^membership username$/i, 	{ type_out => 'login' } ],
	[ 'password',		1, qr/^membership password$/i, 	{ type_out => 'login' } ],
	[ 'url',		1, qr/^membership url$/i, 	{ type_out => 'login' } ],
    ]},
    note =>			{ textname => '', fields => [
    ]},
    password =>			{ textname => '', fields => [
	[ 'url',		1, qr/^password url$/i, ],
	[ 'password',		1, qr/^password$/i, ],
    ]},
    socialsecurity =>		{ textname => '', fields => [
	[ 'name',		0, qr/^name$/i, ],
	[ 'number',		1, qr/^ss number$/i, ],
    ]},
    software =>			{ textname => '', fields => [
	[ 'product_version',	1, qr/^Version$/i, ],
	[ 'reg_code',		1, qr/^License Key$/i, ],
	[ 'reg_name',		1, qr/^Licensed To$/i, ],
	[ 'reg_email',		1, qr/^Registered Email$/i, ],
	[ 'company',		0, qr/^Company$/i, ],
	[ 'download_link',	1, qr/^Download Link$/i, ],
	[ 'publisher_name',	1, qr/^Software Publisher$/i, ],
	[ 'publisher_website',	1, qr/^Publisher's Website$/i, ],
	[ 'retail_price',	1, qr/^Retail Price$/i, ],
	[ 'support_email',	1, qr/^Support Email$/i, ],
	[ 'order_date',		1, qr/^Purchase Date$/i,	{ func => sub { return date2epoch($_[0]) } } ],
	[ 'order_number',	1, qr/^Order Number$/i, ],
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

my $custom_field_num = 1;

my $t = gmtime;

sub do_init {
    # Add the standard meta-data entries (title, notes, tags, created, modified) to each entry
    for my $type (keys %card_field_specs) {
	for my $key (qw/title notes tags created modified/) {
	    push @{$card_field_specs{$type}{'fields'}}, [ $key, 0,  qr/^${key}$/i ];
	}
    }

    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
	'opts'		=> [
	      		     [ q{      --sepchar <char>     # use char as separator character ("tab" is accepted) },
			       'sepchar=s' ],
	],
    }
}

# canonicalize and clean-up column names
sub colmod {
    local $_ = shift;
    $_ =~ s/\s*$//;		# be kind - remove any trailing whitespace from column labels
    $_ = lc $_;
}

sub do_import {
    my ($file, $imptypes) = @_;

    my $sepchar = ',';
    if ($main::opts{'sepchar'}) {
	$sepchar = $main::opts{'sepchar'};
	$sepchar =~ s/^(\\t|tab)$/\t/i;
    }

    my $parsed;
    my @column_names;
    eval { $parsed = csv(
	    in => $file,
	    auto_diag => 1,
	    diag_verbose => 1,
	    detect_bom => 1,
	    sep_char => $sepchar,
	    munge_column_names => \&colmod,
	    keep_headers => \@column_names,
	);
    };
    $parsed or
	bail "Failed to parse file: $file\nSee error hint above.";

    my $itype = find_card_type(\@column_names);

    my %Cards;
    my ($n, $rownum) = (1, 1);

    my @meta = qw/title notes tags modified created/;
    while (my $row = shift @$parsed) {
	debug 'ROW: ', $rownum++;
	next if defined $imptypes and (! exists $imptypes->{$itype});

	my (@fieldlist, %cmeta);
	# save the special fields to pass to normalize_card_data below, and then remove them from the row.

	for (@meta) {
	    my $m = $_;
	    next unless grep { $m eq $_ } @column_names;

	    if ($_ eq 'tags') {
		$cmeta{$_} = [ split /\s*,\s*/, $row->{$_} ];
	    }
	    elsif ($_ eq 'modified' or $_ eq 'created') {
		# if the epoch date appears invalid, or timestamps are disabled, it will be added to @fieldlist instead of the metadata
		if (not $main::opts{'notimestamps'} and validateEpochStr($row->{$_}, $t->epoch)) {
		    $cmeta{$_} = $row->{$_};
		}
		else {
		    debug "Invalid $_ epoch date: ", $row->{$_}		unless $main::opts{'notimestamps'};
		    push @fieldlist, [ $_ => $row->{$_} ];
		}
	    }
	    else {
		$cmeta{$_} = $row->{$_};
	    }
	}
	delete @{$row}{@meta};			# remove the meta fields

	push @fieldlist, [ $_ => $row->{$_} ]	 for keys %$row;

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
    my $row = shift;
    my $otype;

    for my $type (sort by_test_order keys %card_field_specs) {
	for my $cfs (@{$card_field_specs{$type}{'fields'}}) {
	    for (my $i = 0; $i <= $#$row; $i++) {
		if (defined $cfs->[CFS_MATCHSTR] and $row->[$i] =~ /$cfs->[CFS_MATCHSTR]/i) {
		    $otype = $type	 			if $cfs->[CFS_TYPEHINT];
		}
	    }
	}
	last if defined $otype;
    }

    $otype ||= 'note';
    debug "\t\ttype detected as '$otype'";
    return $otype;
}

# sort logins as the last to check
sub by_test_order {
    return  1 if $a eq 'login';
    return -1 if $b eq 'login';
    $a cmp $b;
}


# yyyy-mm-dd or yyyy/mm/dd	for birthdays
# mm/dd/yyyy			for software licenses
# mm/yyyy
# mmyyyy
sub parse_date_string {
    local $_ = $_[0];

    if (s/^(\d{4})[-\/](\d{2})[-\/](\d{2})$/$1-$2-$3/) {
	if (my $t = Time::Piece->strptime($_, "%Y-%m-%d")) {	# KeePass 2 dates are in standard UTC string format
	    return $t;
	}
    }
    elsif (/^(\d{1,2})[\/](\d{1,2})[\/](\d{4})$/) {
	my ($m,$d,$y) = ($1, $2, $3);
	$m = '0' . $m	if length $m eq 1;
	$d = '0' . $d	if length $d eq 1;
	if (my $t = Time::Piece->strptime(join('-', $y, $m, $d), "%Y-%m-%d")) {
	    return $t;
	}
    }
    else {
	s/\///;
	return undef unless /^\d{6}$/;
	if (my $t = Time::Piece->strptime($_, "%m%Y")) {
	    return $t;
	}
    }

    return undef;
}

sub date2monthYear {
    my $t = parse_date_string @_;
    return defined $t->year ? sprintf("%d%02d", $t->year, $t->mon) : $_[0];
}

# epoch seconds to validate, epoch seconds Now
sub validateEpochStr {
    return undef	unless $_[0] =~ /^\d+$/;
    return undef	unless $_[0] >= 0 and $_[0] <= $_[1];	# beween Jan 1 1970 and Now
    return $_[0];
}

sub date2epoch {
    my $t = parse_date_string @_;
    return undef if not defined $t;
    return defined $t->year ? 0 + timelocal(0, 0, 0, $t->mday, $t->mon - 1, $t->year): $_[0];
}

1;
