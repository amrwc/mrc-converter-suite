# LassPass CSV export converter
#
# Copyright 2014 Mike Cappella (mike@cappella.us)

package Converters::Lastpass;

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
use Date::Calc qw(check_date Decode_Month Date_to_Days);
# Force lib included CSV_PP for consistency
BEGIN { $ENV{PERL_TEXT_CSV}='Text::CSV_PP'; }
use Text::CSV qw/csv/;
use IO::String;

=pod

=encoding utf8

=head1 LastPass converter module

=head2 Platforms

=over

=item B<macOS>: Tested with various browser extension versions

=item B<Windows>: Tested with various browser extension versions (initially 3.1.54 Firefox/Windows)

=back

=head2 Description

Converts your exported LastPass data and Form Fill Profiles.

=head2 Instructions

Launch the browser you normally use with LastPass (but first see B<Notes> below).

LastPass will either export your data directly to a file, or it may open a browser window
with the exported data in that window.
More recent version of LastPass tend to do the latter.

If you have the LastPass browser extension installed, from the extension,
and depending on your version of the extension, select either
C<< More Options > Advanced > Export > LastPass CSV File >>
or
C<< Tools > Advanced Tools > Export To > LastPass CSV File >>
and when prompted, enter your LastPass vault password.
If the exported data opens in a browser window, follow the instructions below.
If LastPass opens a C<Save> dialog, navigate to your B<Desktop>>* folder in the C<Select a file to export to> dialog, and in the C<File name> area,
enter the name B<pm_export.txt>, and click C<Save>.

If your LastPass exported data appeared in a separate browser window,
you need to select all of the data on the page, copy it, and save it to a plain text file.

On macOS, select all of the data on the export page (⌘ + A) and Copy it (⌘ + C).
Launch TextEdit, and go to the menu C<< TextEdit > Preferences >>.
In the C<New Document> tab, under C<Format>, select C<Plain Text> and close that dialog.
Open a new document (⌘ + N), and paste the data you copied earlier (⌘ + V).
Save the file to the Desktop with the file name B<pm_export.txt>, selecting C<Unicode (UTF-8)> as the C<Plain Text Encoding>.

On Windows, select all of the data on the export page (Ctrl + A) and Copy it (Ctrl + C).
Launch Notepad, and paste the data your copied earlier (⌘ + V).
Save the data using C<< File > Save As... >> and save the file to the Desktop with the file name B<pm_export>.
By default, Windows will add the C<.txt> suffix.

You may now close the LastPass browser window.

=head2 Notes


The LastPass extension for Chrome incorrectly opens the export as an HTML document.
If you are using Chrome as your browser, do not use the extension to start the export.
Instead, either use the LastPass extension in a different browser, or use the C<< Tools > Advanced > Export >> item in the left
sidebar when your vault is open in the browser (you will have to use the copy / paste method mentioned in the note above).

LastPass exports I<Form Fill Profiles> separately, using the C<< Tools > Advanced Tools > Export To > Form Fill Profiles >> menu.
If you wish to convert and import your Form Fill Profiles, export these to a separate export file, perhaps naming it B<pm_export_ff.txt>.

=head2 Notes

You may specify more than one LastPass export file on the command line.
The converted data will be output into a single 1PIF file for import.
This allows you to convert both of your LastPass data and Form Fill Profiles into a single conversion.

This converter supports cross-platform conversion (the export may be exported on one platform, but converted on another).

=cut

# note: the second field, the type hint indicator (e.g. $card_field_specs{$type}[$i][1]}),
# is not used, but remains for code-consisency with other converter modules.
#
my %card_field_specs = (
    bankacct => 		{ textname => 'Bank Account', fields => [
	[ 'bankName',		0, 'Bank Name' ],
	[ 'accountType',	0, 'Account Type',	{ func => sub {return bankstrconv($_[0])} } ],
	[ 'routingNo',		0, 'Routing Number' ],
	[ 'accountNo',		0, 'Account Number' ],
	[ 'swift',		0, 'SWIFT Code' ],
	[ 'iban',		0, 'IBAN Number' ],
	[ 'telephonePin',	0, 'Pin' ],
	[ 'branchAddress',	0, 'Branch Address' ],
	[ 'branchPhone',	0, 'Branch Phone' ],
    ]},
    creditcard => 		{ textname => 'Credit Card', fields => [
	[ 'cardholder',		0, 'Name on Card' ],
	[ 'type',		0, 'Type',		{ func => sub{return lc $_[0]} } ],
	[ 'ccnum',		0, 'Number' ],
	[ 'cvv',		0, 'Security Code' ],
	[ 'validFrom',		0, 'Start Date',	{ func => sub {return date2monthYear($_[0], 2)} } ],
	[ 'expiry',		0, 'Expiration Date',	{ func => sub {return date2monthYear($_[0], 2)} } ],
    ]},
    database => 		{ textname => 'Database', fields => [
	[ 'database_type',	0, 'Type' ],
	[ 'hostname',		0, 'Hostname' ],
	[ 'port',		0, 'Port' ],
	[ 'database',		0, 'Database' ],
	[ 'username',		0, 'Username' ],
	[ 'password',		0, 'Password' ],
	[ 'sid',		0, 'SID' ],
	[ 'alias',		0, 'Alias' ],
    ]},
    driverslicense => 		{ textname => 'Driver\'s License', fields => [
	[ 'number',		0, 'Number' ],
	[ 'expiry_date',	0, 'Expiration Date',	{ func => sub {return date2monthYear($_[0], 2)}, keep => 1 } ],
	[ 'class',		0, 'License Class' ],
	[ 'fullname',		0, 'Name' ],
	[ 'address',		0, 'Address' ],
	[ 'city',		0, 'City / Town',	{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_string, 'city / town' ] } ],
	[ 'state',		0, 'State' ],
	[ 'zip',		0, 'ZIP / Postal Code',	{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_string, 'zip / postal code' ] } ],
	[ 'country',		0, 'Country' ],
	[ 'birthdate',		0, 'Date of Birth',	{ func => sub {return date2epoch($_[0], -1)} } ],
	[ 'sex',		0, 'Sex' ],
	[ 'height',		0, 'Height' ],

    ]},
    email => 			{ textname => 'Email Account', fields => [
	[ 'pop_username',	0, 'Username' ],
	[ 'pop_password',	0, 'Password' ],
	[ 'pop_server',		0, 'Server' ],
	[ 'pop_port',		0, 'Port' ],
	[ 'pop_type',		0, 'Type' ],
	[ 'smtp_server',	0, 'SMTP Server' ],
	[ 'smtp_port',		0, 'SMTP Port' ],
    ]},
    healthinsurance => 		{ textname => 'Health Insurance', type_out => 'membership', fields => [
	[ 'org_name',		0, 'Company' ],
	[ 'phone',		0, 'Company Phone' ],
	[ 'poltype',		0, 'Policy Type' ],
	[ 'polid',		0, 'Policy Number' ],
	[ 'grpid',		0, 'Group ID',	{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_string, 'group ID' ] } ],
	[ 'member_name',	0, 'Member Name' ],
	[ 'membership_no',	0, 'Member ID' ],
	[ 'physician',		0, 'Physician Name' ],
	[ 'physicianphone',	0, 'Physician Phone' ],
	[ 'physicianaddr',	0, 'Physician Address' ],
	[ 'copay',		0, 'Co-pay' ],
    ]},
    identity =>			{ textname => undef, type_out => 'identity', fields => [		# special handling
	[ 'language', 		0, 'profilelanguage' ],
	[ 'title', 		0, 'title' ],
	[ 'firstname', 		0, 'firstname' ],
	[ 'firstname2', 	0, 'firstname2' ],
	[ 'firstname3', 	0, 'firstname3' ],
	[ 'initial', 		0, 'middlename' ],
	[ 'lastname', 		0, 'lastname' ],
	[ 'lastname2', 		0, 'lastname2' ],
	[ 'lastname3', 		0, 'lastname3' ],
	[ 'username', 		0, 'username' ],
	[ 'sex', 		0, 'gender', 		{ func => sub {return $_[0] =~ /F/i ? 'Female' : 'Male'} } ],
	[ 'birthdate', 		0, 'birthday',		{ func => sub {return date2epoch($_[0], 2)} } ],
	[ 'number', 		0, 'ssn',		{ type_out => 'socialsecurity' } ],
	[ 'name',		0, 'ssnfullname',	{ type_out => 'socialsecurity', as_title => sub {return 'SS# ' . $_[0]{'value'}} } ],
	[ 'company', 		0, 'company' ],

	[ 'address', 		0, 'address' ],		# combined from original fields: address1 address2 address3
	[ 'city', 		0, 'city' ],
	[ 'state', 		0, 'state' ],
	[ 'zip', 		0, 'zip' ],
	[ 'country', 		0, 'country' ],

	[ 'county', 		0, 'county' ],
	[ 'state_name', 	0, 'state_name' ],
	[ 'country_cc3l', 	0, 'country_cc3l' ],
	[ 'country_name', 	0, 'country_name' ],
	[ 'timezone', 		0, 'timezone' ],
	[ 'email', 		0, 'email' ],
	[ 'cellphone', 		0, 'cellphone' ],	# combined from original fields: mobilephone3lcc mobilephone mobileext
	[ 'defphone', 		0, 'defphone' ],	# combined from original fields: phone3lcc phone phoneext
	[ 'fax', 		0, 'fax' ],		# combined from original fields: fax3lcc fax faxext
	[ 'homephone', 		0, 'homephone' ], 	# combined from original fields: evephone3lcc evephone eveext
	[ 'mobilephone3lcc', 	0, 'mobilephone3lcc' ],
	[ 'mobilephone', 	0, 'mobilephone' ],
	[ 'mobileext', 		0, 'mobileext' ],
	[ 'cardholder', 	0, 'ccname',		{ type_out => 'creditcard' } ],
	[ 'ccnum', 		0, 'ccnum',		{ type_out => 'creditcard',	as_title => sub {return 'Credit Card ending ' . last4($_[0]->{'value'})} } ],
	[ 'validFrom', 		0, 'ccstart',		{ type_out => 'creditcard',	func => sub {return date2monthYear($_[0], 2)}, keep => 1 } ],
	[ 'expiry', 		0, 'ccexp',		{ type_out => 'creditcard',	func => sub {return date2monthYear($_[0], 2)}, keep => 1 } ],
	[ 'cvv', 		0, 'cccsc',		{ type_out => 'creditcard' } ],
	[ 'ccissuenum', 	0, 'ccissuenum',	{ type_out => 'creditcard' } ],
	[ 'bankName', 		0, 'bankname',		{ type_out => 'bankacct',	as_title => sub {return $_[0]->{'value'}} } ],
	[ 'accountNo', 		0, 'bankacctnum',	{ type_out => 'bankacct',	to_title => sub {return ' (' . last4($_[0]->{'value'}) . ')'} } ],
	[ 'routingNo', 		0, 'bankroutingnum',	{ type_out => 'bankacct' } ],
	[ 'customfield1text', 	0, 'customfield1text' ],
	[ 'customfield1value', 	0, 'customfield1value' ],
	[ 'customfield1alttext',0, 'customfield1alttext' ],
	[ 'customfield2text', 	0, 'customfield2text' ],
	[ 'customfield2value', 	0, 'customfield2value' ],
	[ 'customfield2alttext',0, 'customfield2alttext' ],
	[ 'customfield3text', 	0, 'customfield3text' ],
	[ 'customfield3value', 	0, 'customfield3value' ],
	[ 'customfield3alttext',0, 'customfield3alttext' ],
	[ 'customfield4text', 	0, 'customfield4text' ],
	[ 'customfield4value', 	0, 'customfield4value' ],
	[ 'customfield4alttext',0, 'customfield4alttext' ],
	[ 'customfield5text', 	0, 'customfield5text' ],
	[ 'customfield5value', 	0, 'customfield5value' ],
	[ 'customfield5alttext',0, 'customfield5alttext' ],
    ]},
    insurance => 		{ textname => 'Insurance', type_out => 'membership', fields => [
	[ 'org_name',		0, 'Company' ],
	[ 'poltype',		0, 'Policy Type',	{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_string, 'policy type' ] } ],
	[ 'polid',		0, 'Policy Number',	{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_string, 'policy ID' ] } ],
	[ 'expiry_date',	0, 'Expiration',	{ func => sub {return date2monthYear($_[0], 2)}, keep => 1 } ],
	[ 'agentname',		0, 'Agent Name',	{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_string, 'agent name' ] } ],
	[ 'phone',		0, 'Agent Phone' ],
	[ 'website',		0, 'URL' ],
    ]},

    instantmessage => 		{ textname => 'Instant Messenger', type_out => 'login', fields => [
	[ 'imtype',		0, 'Type' ],
	[ 'username',		0, 'Username' ],
	[ 'password',		0, 'Password' ],
	[ 'url',		0, 'Server' ],
	[ 'import',		0, 'Port' ],
    ]},
    login => 			{ textname => undef, fields => [	# special handling
	[ 'username',		0, 'username' ],
	[ 'password',		0, 'password' ],
	[ 'url',		0, 'url' ],
    ]},
    note => undef,							# special handling
    membership => 		{ textname => 'Membership', fields => [
	[ 'org_name',		0, 'Organization' ],
	[ 'membership_no',	0, 'Membership Number' ],
	[ 'member_name',	0, 'Member Name' ],
	[ 'member_since',	0, 'Start Date',	{ func => sub {return date2monthYear($_[0], 2) }, keep => 1 } ],
	[ 'expiry_date',	0, 'Expiration',	{ func => sub {return date2monthYear($_[0], 2) }, keep => 1 } ],
	[ 'website',		0, 'Website' ],
	[ 'phone',		0, 'Telephone' ],
	[ 'pin',		0, 'Password' ],
    ]},
    passport => 		{ textname => 'Passport', fields => [
	[ 'type',		0, 'Type' ],
	[ 'fullname',		0, 'Name' ],
	[ 'issuing_country',	0, 'Country' ],
	[ 'number',		0, 'Number' ],
	[ 'sex',		0, 'Sex' ],
	[ 'nationality',	0, 'Nationality' ],
	[ 'issuing_authority',	0, 'Issuing Authority' ],
	[ 'birthdate',		0, 'Date of Birth',	{ func => sub {return date2epoch($_[0], -1)} } ],
	[ 'issue_date',		0, 'Issued Date',	{ func => sub {return date2epoch($_[0], -1)} } ],
	[ 'expiry_date',	0, 'Expiration Date',	{ func => sub {return date2epoch($_[0],  2)} } ],
    ]},
    server => 			{ textname => 'Server', fields => [
	[ 'url',		0, 'Hostname' ],
	[ 'username',		0, 'Username' ],
	[ 'password',		0, 'Password' ],
    ]},
    socialsecurity => 		{ textname => 'Social Security', fields => [
	[ 'name',		0, 'Name' ],
	[ 'number',		0, 'Number' ],
    ]},
    software => 		{ textname => 'Software License', fields => [
	[ 'reg_code',		0, 'License Key' ],
	[ 'product_version',	0, 'Version' ],
	[ 'publisher_name',	0, 'Publisher' ],
	[ 'support_email',	0, 'Support Email' ],
	[ 'publisher_website',	0, 'Website' ],
	[ 'retail_price',	0, 'Price' ],
	[ 'order_date',		0, 'Purchase Date',	{ func => sub {return date2epoch($_[0], 2)} } ],
	[ 'order_number',	0, 'Order Number' ],
	[ 'nlicenses',		0, 'Number of Licenses',{ custfield => [ $Utils::PIF::sn_order,	$Utils::PIF::k_string, 'number of licenses' ] } ],
	[ 'order_total',	0, 'Order Total' ],
    ]},
    sshkey => 			{ textname => 'SSH Key', type_out => 'server', fields => [
	[ 'sshbitstrength',	0, 'Bit Strength',	{ custfield => [ 'server.SSH Info', $Utils::PIF::k_string, 'bit strength' ] } ],
	[ 'sshformat',		0, 'Format',		{ custfield => [ 'server.SSH Info', $Utils::PIF::k_string, 'format' ] } ],
	[ 'sshpassphrase',	0, 'Passphrase',	{ custfield => [ 'server.SSH Info', $Utils::PIF::k_concealed, 'passphrase' ] } ],
	[ 'sshprivkey',		0, 'Private Key',	{ custfield => [ 'server.SSH Info', $Utils::PIF::k_concealed, 'private key' ] } ],
	[ 'sshpubkey',		0, 'Public Key',	{ custfield => [ 'server.SSH Info', $Utils::PIF::k_string, 'public key' ] } ],
	[ 'admnin_console_url',	0, 'Hostname' ],
	[ 'sshdate',		0, 'Date',		{ custfield => [ 'server.SSH Info', $Utils::PIF::k_string, 'date' ] } ],
    ]},
    wireless => 		{ textname => 'Wi-Fi Password', fields => [
	[ 'network_name',	0, 'SSID' ],
	[ 'wireless_password',	0, 'Password' ],
	[ 'wireless_conntype',	0, 'Connection Type' ],
	[ 'wireless_connmode',	0, 'Connection Mode' ],
	[ 'wireless_auth',	0, 'Authentication' ],
	[ 'wireless_encrypt',	0, 'Encryption' ],
	[ 'wireless_use8201x',	0, 'Use 802.1X' ],
	[ 'wireless_fipsmode',	0, 'FIPS Mode' ],
	[ 'wireless_keytype',	0, 'Key Type' ],
	[ 'wireless_protected',	0, 'Protected' ],
	[ 'wireless_keyindex',	0, 'Key Index' ],
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

my @today = Date::Calc::Today();			# for date comparisons

sub do_init {
    return {
	specs		=> \%card_field_specs,
	imptypes  	=> undef,
	filelist_ok     => 1,
	opts		=> [],
    };
}

sub do_import {
    my ($files, $imptypes) = @_;

    my %Cards;
    my $n = 1;
    for my $file (ref($files) eq 'ARRAY' ? @$files : $files) {

	# remove BOM and any intial and trailing superfluous newlines
	my $data = slurp_file($file, 'utf8');
	$data =~ s/\A\N{BOM}//;
	$data =~ s/\A\R+//;
	$data =~ s/\R+\z//;
	my $io = IO::String->new($data);

	my $parsed;
	my @column_names;
	eval { $parsed = csv(
		in => $io,
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

	my $rownum = 1;
	my %saved_ssns;
	while (my $hr = shift @$parsed) {
	    debug 'ROW: ', $rownum++;

	    my ($itype, %cmeta, @fieldlist);

	    # Switch on the form of CSV export:
	    #    - standard entries (LastPass CSV File)
	    #    - profiles (Form Fill Profiles)
	    if (! exists $hr->{'profilename'}) {
		# LastPass CSV field order / header names
		#
		#    url, username, password, extra, name, grouping, fav
		#
		# LastPass CSV File export has two types: Site and Secure Note
		#
		# Field 'extra' contains lines of specific secure notes label:value pairs
		# Secure notes types will have URL = "http://sn"

		$cmeta{'title'} =  $hr->{'name'};
		$cmeta{'notes'} =  $hr->{'extra'};
		push @{$cmeta{'tags'}}, 'Favorite'		if $hr->{'fav'} == 1;
		if ($hr->{'grouping'} ne '(none)' and $hr->{'grouping'} ne '') {
		    my @grouping = join '/', split(/\\/, $hr->{'grouping'});
		    push @{$cmeta{'tags'}}, @grouping;
		    @{$cmeta{'folder'}} = @grouping;
		}

		if ($hr->{'url'} ne 'http://sn') {
		    $itype = 'login';
		    for (qw/username password url/) {
			push @fieldlist, [ $_ => $hr->{$_} ]	if $hr->{$_} ne '';
		    }
		}
		else {
		    $itype = pull_fields_from_note(\@fieldlist, \$cmeta{'notes'});
		}
		debug "\t\ttype determined as '$itype'";
		# skip all types not specifically included in a supplied import types list
		next if defined $imptypes and (! exists $imptypes->{$itype});
	    }
	    # Form Fill profiles will map to one or more 1P4 types:
	    #    Identity, Credit Card, Bank Account, and Social Security Number
	    else {
		# LastPass Form Fill Profiles export 

		$itype = 'identity';
		debug "\t\ttype determined as '$itype'";
		# skip all types not specifically included in a supplied import types list
		next if defined $imptypes and (! exists $imptypes->{$itype});
		
		my $fullname = join ' ', $hr->{'firstname'}, $hr->{'lastname'};
		$cmeta{'title'} = $fullname;

		$cmeta{'notes'} = 'Form Fill Profile: ' . $hr->{'profilename'};		delete $hr->{'profilename'};
		$cmeta{'notes'} .= "\n" . $hr->{'notes'}	if $hr->{'notes'} ne '';	delete $hr->{'notes'};

		$hr->{'ssnfullname'}  = $fullname;
		$hr->{'defphone'}	  = join ' ',  grep {$_ ne ''} map {$hr->{$_}} qw/phone3lcc phone phoneext/; 
		$hr->{'homephone'}	  = join ' ',  grep {$_ ne ''} map {$hr->{$_}} qw/evephone3lcc evephone eveext/; 
		$hr->{'cellphone'}	  = join ' ',  grep {$_ ne ''} map {$hr->{$_}} qw/mobilephone3lcc mobilephone mobileext/; 
		$hr->{'fax'}	  = join ' ',  grep {$_ ne ''} map {$hr->{$_}} qw/fax3lcc fax faxext/; 
		$hr->{'address'}{'street'}	  = join ', ', grep {$_ ne ''} map {$hr->{$_}} qw/address1 address2 address3/; 
		for (qw/city state country zip/) {
		    $hr->{'address'}{$_} = $hr->{$_};
		    delete $hr->{$_};
		}
		delete $hr->{$_} for qw/address1 address2 address3 phone3lcc phone phoneext
					evephone3lcc evephone eveext mobilephone3lcc mobilephone mobileext fax3lcc fax faxext/;

		# Social Security fields
		if ($hr->{'ssn'} ne '') {
		    # save the SSN #'s to avoid duplicate SS cards
		    if (++$saved_ssns{$hr->{'ssn'} =~ s/[-\s]//gr} > 1) {
			verbose("Skipped creating duplicate social security entry from form profile");
			delete $hr->{'ssn'};
		    }
		}

		for (keys %$hr) {
		    debug "KEY: $_";
		    push @fieldlist, [ $_ => $hr->{$_} ]		if defined $hr->{$_} and $hr->{$_} ne '';
		}
	    }

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

sub pull_fields_from_note {
    my ($fieldlist, $notes) = @_;

    my $type = 'note';

    # The first entry in the note indicates the note type (e.g. NoteType:Bank Account)
    # It may be a custom type of the form Custom_####.
    if ($$notes =~ s/^NoteType:(.+?)(?:\R+|\Z)//ms) {
	my $notetype = $1;
	debug "Custom note type: $notetype"	if $notetype =~ /^Custom_\d+$/;

	my $cfs = \%card_field_specs;
	my @found = grep { 
		defined $cfs->{$_}->{'textname'} and
		( ref $cfs->{$_}->{'textname'} eq 'Regexp' ?
		    $notetype =~ $cfs->{$_}->{'textname'} :
		    $cfs->{$_}->{'textname'} eq $notetype 
		)
	    } keys %$cfs;

	if (@found == 1) {
	    $type = $found[0];
	}
	elsif (@found == 0) {
	    debug '   Unmatched';
	}
	else {
	    debug "   Matched multiple categories: @found";
	}

	# When a match is found, or the type is Custom, pull the key/value pairs
	# from the notes area.
	if (@found or $notetype =~ /^Custom_\d+$/) {
	    my $newnote;
	    for my $kvpair (split /\R+/, $$notes) {
		my ($key, $value) = split /:/, $kvpair, 2;
		next if not defined $value or $value eq '';
		if ($key eq 'Notes') {
		    $newnote = $value;
		}
		else {
		    push @$fieldlist, [ $key => $value ];		# maintains original order
		}
	    }
	    $$notes = $newnote // undef;
	}
	return $type;
    }

    return $type;
}

# input conversion routines
#
sub bankstrconv {
    local $_ = shift;
    return  'savings' 		if /sav/i;
    return  'checking'		if /check/i;
    return  'loc'		if /line|loc|credit/i;
    return  'amt'		if /atm/i;
    return  'money_market'	if /money|market|mm/i;
    return  'other';
}

# Date converters
# lastpass dates: month,d,yyyy   month,yyyy   yyyy-mm-dd
sub parse_date_string {
    local $_ = $_[0];
    my $when = $_[1] || 0;					# -1 = past only, 0 = assume this century, 1 = future only, 2 = 50-yr moving window

    if (/^(?<m>[^,]+),(?:(?<d>\d{1,2}),)?(?<y>\d{4})$/ or	# month,d,yyyy or month,yyyy
	/^(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})$/) { 		# yyyy-mm-dd
	my $days_today = Date_to_Days(@today);

	my $d_present = exists $+{'d'};
	my $d = sprintf "%02d", $+{'d'} // "1";
	my $m = $+{'m'};
	my $origy = $+{'y'};
	$m = sprintf "%02d", $m !~ /^\d{1,2}$/ ? Decode_Month($m) : $m;
	for my $century (qw/20 19/) {
	    my $y = $origy;
	    if (length $y eq 2) {
		$y = sprintf "%d%02d", $century, $y;
		$y = Moving_Window($y)	if $when == 2;
	    }
	    if (check_date($y, $m, $d)) {
		next if ($when == -1 and Date_to_Days($y,$m,$d) > $days_today);
		next if ($when ==  1 and Date_to_Days($y,$m,$d) < $days_today);
		return ($y, $m, $d_present ? $d : undef);
	    }
	}
    }

    return undef;
}

sub date2monthYear {
    my ($y, $m, $d) = parse_date_string @_;
    return defined $y ? $y . $m	: $_[0];
}

sub date2epoch {
    my ($y, $m, $d) = parse_date_string @_;
    return defined $y ? timelocal(0, 0, 3, $d, $m - 1, $y): $_[0];
}

sub last4 {
    local $_ = shift;
    s/[- ._:]//;
    /(.{4})$/;
    return $1;
}

1;
