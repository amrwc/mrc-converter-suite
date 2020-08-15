# Enpass JSON / CSV export converter
#
# Copyright 2018 Mike Cappella (mike@cappella.us)

package Converters::Enpass;

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
use IO::String;
# Force lib included CSV_PP for consistency
BEGIN { $ENV{PERL_TEXT_CSV}='Text::CSV_PP'; }
use Text::CSV qw/csv/;

=pod

=encoding utf8

=head1 Enpass converter module

=head2 Platforms

=over

=item B<macOS>: Initially tested with version 5.6.3; version 6 beta in progress

=item B<Windows>: Initially tested with version 5.6.3; version 6 beta in progress

=back

=head2 Description

Converts your exported Enpass data to 1PIF for 1Password import.

=head2 Instructions

Launch Enpass and set the language to English under C<Tools E<gt> Settings E<gt> Advanced E<gt> Language>.
Quit Enpass completely and relaunch it.
The language must be set to English so that field names in the export file can match those expected by the converter.

B<Enpass version 6>:
Export your data as B<JSON>.
Use the C<File E<gt> Export> menu, select the vault from the C<Select Vault You Want to Export> pulldown, and select the C<.json> format.
Select your B<Desktop> folder under the C<Choose Location> selector, enter the file name B<pm_export>, and click C<Save>.
Now click the C<Export> button, provide your master password when the Export dialog appears, and click the C<Continue> button.
Next click the C<Done> button.
There will now be a file on your Desktop named B<pm_export.json> - use this file name on the command line.

B<Enpass versions prior to 6>:
Export your Enpass data as B<CSV>.
Use the C<File E<gt> Export E<gt> as CSV> menu.
Provide your master password when the Export dialog appears, and click the C<OK> button.
Next click the C<OK> button in the dialog that warns you about the data export being unprotected.
In the C<Save> dialog, navigate to your B<Desktop> folder, and save the file with the name B<pm_export.txt> to your Desktop.

You may now quit Enpass.

=head2 Notes

Enpass' CSV exports are problematic and ambiguous.
The converter attempts to handle these situations, but some data can cause issues.
In such cases, you may need to open your export file in a spreadsheet and correct any entries that have been split into two rows , and re-export to CSV in UTF-8 format.

There are several generic I<Other> categories in Enpass, and these contain only two stock fields "Field 1" and "Field 2".
Because these records are indistinguishable in the export, the converter maps them to a single B<other> category.

Most of Enpass' field values are free-form text (they are not validated, and may be nonsensical).
Given this, the converter will not attempt to place some values into a specific 1Password field, but instead must place these
values into the Notes area as label / value pairs.

Records imported into Enpass 6 from another password manager are not converted to Enpass' own internal categories.
They are instead placed into a generic category.
The converter cannot automatically determine the record type for these records,
because the field names and semantics vary based on the original password manager.
The result will be that many of your records will convert as Secure Notes.
The converter can be customized to handle your data.
If you are in this situation, use the C<--dumpcats> option to examine the field names present in
the "import.imported" category shown in the output.
You can decide which of these fields should be mapped to the username, password, and URL fields
for a Login category.
There is a commented-out entry in the Enpass.pm converter file's table of category/field names
which can be uncommented and tailored to your data.
Ask if you need help.

=cut

my %card_field_specs = (
# The entry below can be uncommented and customized to deal with login entries that were
# imported into Enpass.  Enpass does not try to categorize a user's imported records; instead
# it places such entries, with their original fields, into the "import.imported" category.
# Because the field names vary widly, depending upon the original password manager, these
# cannot be automatically matched.
#   implogin =>			{ textname => 'import.imported', type_out => 'login', fields => [
#	[ 'username',		3, qr/^UserName$/, ],
#	[ 'password',		3, qr/^Password$/, ],
#	[ 'url',		3, qr/^URL$/, ],
#   ]},
    bankacct =>			{ textname => 'finance.bankaccount', fields => [
	[ 'bankName',		1, qr/^Bank name$/, ],
	[ 'owner',		1, qr/^Account holder$/, ],
	[ 'accountType',	0, qr/^(?:Type|Account type)$/, ],
	[ 'accountNo',		0, qr/^Account number$/, ],
	[ '_customerid',	0, qr/^Customer ID$/, ],
	[ 'routingNo',		1, qr/^Routing number$/, ],
	[ '_branchname',	1, qr/^Branch name$/, ],
	[ '_branchcode',	1, qr/^Branch code$/, ],
	[ 'branchAddress',	1, qr/^Branch address$/, ],
	[ 'branchPhone',	1, qr/^Branch phone$/, ],
	[ 'swift',		1, qr/^SWIFT$/, ],
	[ 'iban',		1, qr/^IBAN$/, ],
	[ 'ccnum',		1, qr/^Debit [Cc]ard number$/,	{ type_out => 'creditcard', to_title => sub {' (debit card ' . last4($_[0]->{'value'}) . ')'} }  ],
	[ 'type',		0, qr/^(?:Type___\d+|Card type)$/,{ type_out => 'creditcard' } ], # avoid duplicate: Type
	[ 'pin',		0, qr/^PIN$/,			{ type_out => 'creditcard' } ],
	[ 'cvv',		1, qr/^CVV$/, 			{ type_out => 'creditcard' } ],
	[ '_expiry',		0, qr/^Expiry date$/, 		{ type_out => 'creditcard' } ],
	[ 'cashLimit',		0, qr/^Withdrawal limit$/, 	{ type_out => 'creditcard' } ],
	[ 'phoneLocal',		0, qr/^Helpline$/,		{ type_out => 'creditcard' } ],
	[ '_tpin',		1, qr/^T-PIN$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Login password$/,	{ type_out => 'login' } ],
    ]},
    combinationlock =>          { textname => '', type_out => 'note', fields => [
        [ 'combolocation',      2, 'Location' ],
        [ '_code',          	2, 'Code',		{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_concealed, 'password', 'generate'=>'off' ] } ],
    ]},
    creditcard =>		{ textname => 'creditcard.default', fields => [
	[ 'cardholder',		1, qr/^Cardholder$/, ],
	[ 'type',		0, qr/^Type$/, ],
	[ 'ccnum',		0, qr/^Number$/, ],
	[ 'cvv',		1, qr/^CVC$/, ],
	[ 'pin',		0, qr/^PIN$/, ],
	[ '_expiry',		0, qr/^Expiry date$/, ],
	[ '_validfrom',		0, qr/^Valid from$/, ],
	[ 'creditLimit',	1, qr/^Credit limit$/, ],
	[ 'cashLimit',		0, qr/^Withdrawal limit$/, ],
	[ 'interest',		0, qr/^Interest rate$/, ],
	[ 'bank',		1, qr/^Issuing bank$/, ],
	[ '_tpassword',		1, qr/^Transaction password$/, ],
	[ '_issuedon',		0, qr/^Issued on$/, ],
	[ '_iflostphone',	0, qr/^If lost, call$/, ],
	[ 'url',		0, qr/^Website$/,			{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,			{ type_out => 'login' } ],
	[ 'password',		0, qr/^(?:Password|Login password)$/,	{ type_out => 'login' } ],
    ]},
    database =>			{ textname => 'computer.database', fields => [
	[ 'database_type',	0, qr/^Type$/, ],
	[ 'hostname',		0, qr/^Server$/, ],
	[ 'port',		0, qr/^Port$/, ],
	[ 'database',		0, qr/^Database$/, ],
	[ 'username',		0, qr/^Username$/, ],
	[ 'password',		0, qr/^Password$/, ],
	[ 'sid',		1, qr/^SID$/, ],
	[ 'alias',		1, qr/^Alias$/, ],
	[ 'options',		1, qr/^Options$/, ],
    ]},
    driverslicense =>		{ textname => 'license.driving', fields => [
	[ 'number',		0, qr/^Number$/, ],
	[ 'fullname',		0, qr/^Name$/, ],
	[ 'sex',		0, qr/^(Sex|Gender)$/, ],
	[ '_birthdate',		1, qr/^Birth date$/, ],
	[ 'address',		0, qr/^Address$/, ],
	[ 'height',		1, qr/^Height$/, ],
	[ 'class',		1, qr/^Class$/, ],
	[ 'conditions',		1, qr/^Restrictions$/, ],
	[ 'state',		0, qr/^State$/, ],
	[ 'country',		0, qr/^Country$/, ],
	[ '_expiry_date',	0, qr/^Expiry date$/, ],
	[ '_issuedon',		0, qr/^Issued on$/, ],
	[ '_iflostcall',	0, qr/^If lost, call$/, ],
    ]},
    email =>			{ textname => 'computer.emailaccount', fields => [
	[ '_email',		0, qr/^E-?mail$/, ],
	[ 'pop_username',	0, qr/^Username$/, ],
	[ 'pop_password',	0, qr/^Password$/, ],
	[ 'pop_type',		0, qr/^(?:Type|Server type)$/, ],
	[ 'pop_server',		1, qr/^POP3 server$/, ],
	[ 'imap_server',	1, qr/^IMAP server$/, ],
	[ 'pop_port',		0, qr/^(?:Port|Port number:::INCOMING SERVER:::6)$/, ],
	[ 'pop_security',	1, qr/^Security type$/, ],
	[ 'pop_authentication',	1, qr/^(?:Auth\. method|Auth. method:::INCOMING SERVER:::11)$/, ],
	[ '_weblink',		1, qr/^Weblink$/, ],
	[ 'smtp_server',	1, qr/^SMTP server$/, ],
	[ 'smtp_port',		0, qr/^(?:Port___\d+|Port number:::OUTGOING SERVER:::7)$/, ],
	[ 'smtp_username',	0, qr/^(?:Username___\d+|Username:::OUTGOING SERVER:::13)$/, ],
	[ 'smtp_password',	0, qr/^(?:Password___\d+|Password:::OUTGOING SERVER:::14)$/, ],
	[ 'smtp_security',	0, qr/^(?:Security type___\d+|Security type:::OUTGOING SERVER:::15)$/, ],
	[ 'smtp_authentication',0, qr/^(?:Auth\. method___\d+|Auth. method:::OUTGOING SERVER:::16)$/, ],
	[ 'provider',		0, qr/^Provider$/, ],
	[ 'provider_website',	0, qr/^Website$/, ],
	[ 'phone_local',	0, qr/^Local phone$/, ],
	[ '_helpline',		0, qr/^Helpline$/,  { custfield => [ $Utils::PIF::sn_eContactInfo, $Utils::PIF::k_string, 'helpline' ] } ],
    ]},
    flightdetail =>		{ textname => '', type_out => 'note', fields => [
	[ '_flightnum',		1, qr/^Flight number$/, ],
	[ '_airline',		0, qr/^Airline$/, ],
	[ '_date',		0, qr/^Date$/, ],
	[ '_from',		0, qr/^From$/, ],
	[ '_to',		0, qr/^To$/, ],
	[ '_timegate',		1, qr/^Time\/Gate$/, ],
	[ '_eticket',		1, qr/^E-Ticket number$/, ],
	[ '_confirmnum',	1, qr/^Confirm #$/, ],
	[ '_phone',		0, qr/^Phone$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    frequentflyer =>		{ textname => 'travel.freqflyer', type_out => 'rewards', fields => [
	[ 'membership_no',	1, qr/^Membership (No\.|number)$/, ],
	[ 'member_name',	0, qr/^Name$/, ],
	[ 'company_name',	0, qr/^Airline$/, ],
	[ '_date',		0, qr/^Date$/, ],
	[ '_mileage',		1, qr/^Mileage$/, ],
	[ 'customer_service_phone',1, qr/^Customer service$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    ftp =>			{ textname => 'computer.ftp', type_out => 'server', fields => [
	[ 'url',		0, qr/^Server$/, ],
	[ '_path',		1, qr/^Path$/, ],
	[ 'username',		0, qr/^Username(:::__MAIN:::2)?$/, ],
	[ 'password',		0, qr/^Password(:::__MAIN:::3)?$/, ],
	[ 'website',		0, qr/^Website$/, ],
	[ 'support_contact_phone',0, qr/^Phone( number)?$/, ],
	[ 'name',		0, qr/^Provider$/, ],
    ]},
    hotelreservations =>	{ textname => '', type_out => 'note', fields => [
	[ '_hotelname',		1, qr/^Hotel name$/, ],
	[ '_roomnum',		1, qr/^Room number$/, ],
	[ '_address',		0, qr/^Address$/, ],
	[ '_reservationid',	1, qr/^Reservation ID$/, ],
	[ '_date',		0, qr/^Date$/, ],
	[ '_nights',		1, qr/^Nights$/, ],
	[ '_hotelreward',	1, qr/^Hotel reward$/, ],
	[ '_phone',		0, qr/^Phone$/, ],
	[ '_email',		0, qr/^Email$/, ],
	[ '_concierge',		1, qr/^Concierge$/, ],
	[ '_restaurant',	1, qr/^Restaurant$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    identity =>			{ textname => 'identity.default', type_out => 'identity', fields => [
	[ 'initial',		1, qr/^Initial$/, ],
	[ 'firstname',		1, qr/^First name$/, ],
	[ 'lastname',		1, qr/^Last name$/, ],
	[ 'sex',		1, qr/^Gender$/, ],
	[ '_birthdate',		1, qr/^Birth date$/, ],
	[ 'number',		1, qr/^Social Security Number$/,  { type_out => 'socialsecurity' } ],
	[ '_home_street',	1, qr/^Street:::HOME ADDRESS/, ],
	[ '_home_city',		1, qr/^City:::HOME ADDRESS/, ],
	[ '_home_state',	1, qr/^State:::HOME ADDRESS/, ],
	[ '_home_country',	1, qr/^Country:::HOME ADDRESS/, ],
	[ '_home_zip',		1, qr/^Zip:::HOME ADDRESS/, ],
	[ 'address',		1, qr/^HOME ADDRESS$/, ],
	[ 'occupation',		1, qr/^Occupation$/, ],
	[ 'company',		1, qr/^Company$/, ],
	[ 'department',		1, qr/^Department$/, ],
	[ 'jobtitle',		1, qr/^Job title$/, ],
	[ 'defphone',		1, qr/^Phone number$/, ],
	[ 'homephone',		1, qr/^Phone home$/, ],
	[ 'busphone',		1, qr/^Phone work$/, ],
	[ 'skype',		1, qr/^Skype$/, ],
	[ 'yahoo',		1, qr/^Yahoo$/, ],
	[ 'msn',		1, qr/^MSN$/, ],
	[ 'icq',		1, qr/^ICQ$/, ],
	[ 'aim',		1, qr/^AIM$/, ],
	[ 'website',		1, qr/^Website$/, ],
	[ 'username',		1, qr/^Username$/, ],
	[ 'email',		1, qr/^E-mail$/, ],
	[ 'password',		1, qr/^Password$/, ],
	[ 'reminderq',		1, qr/^Secret question$/, ],
	[ 'remindera',		1, qr/^Secret answer$/, ],
	[ 'forumsig',		1, qr/^Signature$/, ],
    ]},
    instantmsg =>		{ textname => '', type_out => 'login', fields => [
	[ '_type',		0, qr/^Type$/, ],
	[ '_id',		1, qr/^ID$/, ],
	[ 'url',		0, qr/^Server$/, ],
	[ '_port',		0, qr/^Port$/, ],
	[ '_nickname',		1, qr/^Nick name$/, ],
	[ 'username',		0, qr/^Username$/, ],
	[ 'password',		0, qr/^Password$/, ],
    ]},
    insurance =>		{ textname => 'finance.insurance', text_out => 'note', fields => [
	[ '_policyname',	1, qr/^Policy name$/, ],
	[ '_company',		0, qr/^Company$/, ],
	[ '_policyholder',	1, qr/^Policy holder$/, ],
	[ '_number',		0, qr/^Number$/, ],
	[ '_type',		0, qr/^Type$/, ],
	[ '_premium',		1, qr/^Premium$/, ],
	[ '_sum_assured',	1, qr/^Sum assured$/, ],
	[ '_issuedate',		0, qr/^Issue date$/, ],
	[ '_renewaldate',	1, qr/^Renewal date$/, ],
	[ '_expirydate',	0, qr/^Expiry date$/, ],
	[ '_term',		0, qr/^Term$/, ],
	[ '_nominee',		1, qr/^Nominee$/, ],
	[ '_customerid',	0, qr/^Customer ID$/, ],
	[ '_agentname',		1, qr/^Agent name$/, ],
	[ '_helpline',		0, qr/^Helpline$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    isp =>			{ textname => '', type_out => 'note', fields => [
	[ '_username',		0, qr/^Username$/, ],
	[ '_password',		0, qr/^Password$/, ],
	[ '_dialupphone',	1, qr/^Dialup phone$/, ],
	[ '_isp_system',	1, qr/^ISP\/System$/, ],
	[ '_ip_address',	0, qr/^IP address$/, ],
	[ '_subnetmask',	1, qr/^Subnet mask$/, ],
	[ '_gateway',		1, qr/^Gateway$/, ],
	[ '_primarydns',	1, qr/^Primary DNS$/, ],
	[ '_secondarydns',	1, qr/^Secondary DNS$/, ],
	[ '_wins',		1, qr/^WINS$/, ],
	[ '_smtp',		1, qr/^SMTP$/, ],
	[ '_pop3',		1, qr/^POP3$/, ],
	[ '_nntp',		1, qr/^NNTP$/, ],
	[ '_ftp',		0, qr/^FTP$/, ],
	[ '_telnet',		1, qr/^Telnet$/, ],
	[ '_helpline',		0, qr/^Helpline$/, ],
	[ '_website',		0, qr/^Website$/, ],
	[ '_billinginfo',	0, qr/^Billing info$/, ],
    ]},
    library =>			{ textname => 'misc.library', type_out => 'membership', fields => [
	[ '_address',		0, qr/^Address$/, ],
	[ 'membership_no',	0, qr/^Card number$/, ],
	[ '_expiry_date',	0, qr/^Expiry date$/, ],
	[ '_hours',		0, qr/^Hours$/, ],
	[ '_iflostcall',	0, qr/^If lost, call$/, ],
	[ '_issued_on',		1, qr/^Issued on$/, ],
	[ 'pin',		0, qr/^PIN$/, ],
	[ '_library',		0, qr/^Library$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},

    loanmort =>			{ textname => '', text_out => 'note', fields => [
	[ '_lender',		1, qr/^Lender$/, ],
	[ '_type',		0, qr/^Type$/, ],
	[ '_accountnum',	0, qr/^Account number$/, ],
	[ '_principal',		1, qr/^Principal$/, ],
	[ '_interest',		1, qr/^Interest %$/, ],
	[ '_date',		0, qr/^Date$/, ],
	[ '_term',		0, qr/^Term$/, ],
	[ '_balanace',		1, qr/^Balance$/, ],
	[ '_paymentdue',	1, qr/^Payment due$/, ],
	[ '_asset',		1, qr/^Asset$/, ],
	[ '_phone',		0, qr/^Phone$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    login =>			{ textname => 'login.default', fields => [
	[ 'username',		3, qr/^Username$/, ],
	[ 'password',		3, qr/^Password$/, ],
	[ 'url',		3, qr/^URL|Website$/, ],
	[ '_totp',		3, qr/^TOTP$/, 			{ custfield => [ $Utils::PIF::sn_details, $Utils::PIF::k_totp, 'totp' ] }  ],
	[ '_secQ',		3, qr/^Security [Qq]uestion$/,	{ custfield => [ $Utils::PIF::sn_details, $Utils::PIF::k_string, 'security question' ] } ],
	[ '_secA',		3, qr/^Security [Aa]nswer$/,	{ custfield => [ $Utils::PIF::sn_details, $Utils::PIF::k_concealed, 'security answer' ] } ],
	[ '_phone',		0, qr/^Phone( number)?$/, ],
    ]},
    membership =>		{ textname => 'misc.membership', fields => [
	[ 'membership_no',	0, qr/^Member ID$/, ],
	[ 'member_name',	1, qr/^Member name$/, ],
	[ 'org_name',		1, qr/^Organization$/, ],
	[ '_group',		1, qr/^Group$/, ],
	[ 'pin',		0, qr/^PIN$/, ],
	[ 'phone',		0, qr/^Phone( number)?$/, ],
	[ '_member_since',	1, qr/^Member since$/, ],
	[ '_expiry_date',	0, qr/^Expiry date$/, ],
	[ '_email',		0, qr/^E-?mail$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login', keep => 1 } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
	[ '_iflostcall',	0, qr/^If lost, call$/, ],
    ]},
    mutualfund =>		{ textname => '', text_out => 'note', fields => [
	[ '_fundname',		1, qr/^Fund name$/, ],
	[ '_fundtype',		1, qr/^Fund type$/, ],
	[ '_launchedon',	0, qr/^Launched on$/, ],
	[ '_purchasedon',	0, qr/^Purchased on$/, ],
	[ '_quantity',		0, qr/^Quantity$/, ],
	[ '_puchasednav',	1, qr/^Purchased NAV$/, ],
	[ '_currentnav',	1, qr/^Current NAV$/, ],
	[ '_broker',		0, qr/^Broker$/, ],
	[ '_brokerphone',	0, qr/^Phone$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    note =>			{ textname => 'note', fields => [
    ]},
    other =>			{ textname => '', text_out => 'note', fields => [
	[ '_field1',		2, qr/^Field 1$/, ],
	[ '_field2',		2, qr/^Field 2$/, ],
    ]},
    outdoorlicense =>		{ textname => '', fields => [
	[ 'number',		0, qr/^Number$/, ],
	[ 'name',		0, qr/^Name$/, ],
	[ 'state',		0, qr/^State$/, ],
	[ '_region',		1, qr/^Region$/, ],
	[ 'country',		0, qr/^Country$/, ],
	[ '_validfrom',		0, qr/^Valid from$/, ],
	[ '_expires',		0, qr/^Expiry date$/, ],
	[ 'game',		1, qr/^Approved wildlife$/, ],
	[ 'quota',		1, qr/^Quota$/, ],
    ]},
    passport =>			{ textname => '', fields => [
	[ 'number',		0, qr/^Number$/, ],
	[ 'fullname',		0, qr/^Full name$/, ],
	[ 'sex',		0, qr/^Sex$/, ],
	[ 'type',		0, qr/^Type$/, ],
	[ 'nationality',	1, qr/^Nationality$/, ],
	[ 'birthplace',		1, qr/^Birth place$/, ],
	[ '_birthdate',		1, qr/^Birthday$/, ],
	[ '_issued_at',		1, qr/^Issued at$/, ],
	[ '_issue_date',	0, qr/^Issued on$/, ],
	[ '_expiry_date',	0, qr/^Expiry date$/, ],
	[ 'issuing_country',	1, qr/^Issuing country$/, ],
	[ 'issuing_authority',	1, qr/^Authority$/, ],
	[ '_replacements',	1, qr/^Replacements$/, ],
	[ '_iflostcall',	0, qr/^If lost, call$/, ],
    ]},
    password =>			{ textname => 'password.default', type_out => 'login', fields => [
	[ 'username',		0, qr/^Login$/, ],
	[ 'password',		0, qr/^Password$/, ],
	[ '_access',		1, qr/^Access$/, ],
	[ '_number',		0, qr/Number$/, ],
    ]},
    rewards =>			{ textname => '', fields => [
	[ 'company_name',	0, qr/^Company$/, ],
	[ 'member_name',	0, qr/^Name$/, ],
	[ '_memberid',		0, qr/^Member ID$/, ],
	[ 'membership_no',	0, qr/^Number$/, ],
	[ 'pin',		0, qr/^PIN$/, ],
	[ 'additional_no',	1, qr/^Number 2$/, ],
	[ '_member_since',	1, qr/^Since$/, ],
	[ 'customer_service_phone',0, qr/^Helpline$/, ],
	[ 'reservations_phone',	1, qr/^Reservations phone$/, ],
	[ 'website',		0, qr/^Website$/, ],
    ]},
    server =>			{ textname => '', fields => [
	[ 'admin_console_username', 0, qr/^Admin login$/, ],
	[ 'admin_console_password', 0, qr/^Admin password$/, ],
	[ 'admin_console_url',	0, qr/^Admin URL$/, ],
	[ '_service',		1, qr/^Service$/, ],
	[ '_tasks',		1, qr/^Tasks$/, ],
	[ '_os',		0, qr/^OS$/, ],
	[ '_ram',		1, qr/^RAM$/, ],
	[ '_storage',		1, qr/^Storage$/, ],
	[ '_cpu',		1, qr/^CPU$/, ],
	[ '_raid',		1, qr/^RAID$/, ],
	[ '_location',		0, qr/^Location$/, ],
	[ '_ipaddress',		0, qr/^IP address$/, ],
	[ '_dns',		0, qr/^DNS$/, ],
	[ '_port',		0, qr/^Port$/, ],
	[ 'name',		0, qr/^Hosting provider$/, ],
	[ 'support_contact_url',0, qr/^Support website$/, ],
	[ 'support_contact_phone', 0, qr/^Helpline$/, ],
	[ '_billinginfo',	0, qr/^Billing info$/, ],
    ]},
    socialsecurity =>		{ textname => 'misc.socialsecurityno', fields => [
	[ 'number',		3, qr/^Number$/, ],
	[ 'name',		3, qr/^Name$/, ],
	[ '_date',		3, qr/^Date$/, ],
    ]},
    software =>			{ textname => 'license.software', fields => [
	[ 'product_version',	0, qr/^Version$/, ],
	[ '_product_name',	1, qr/^Product name$/,		{ to_title => 'value' } ],
	[ '_numusers',		1, qr/^No\. of users$/, ],
	[ 'reg_code',		1, qr/^Key$/, ],
	[ 'download_link',	1, qr/^Download page$/, ],
	[ 'reg_name',		1, qr/^Licensed to$/, ],
	[ 'reg_email',		0, qr/^(?:Email|Registered e-mail)$/, ],
	[ 'company',		0, qr/^Company$/, ],
	[ '_order_date',	1, qr/^Purchase date$/, ],
	[ 'order_number',	1, qr/^Order number$/, ],
	[ 'retail_price',	1, qr/^Retail price$/, ],
	[ 'order_total',	0, qr/^Total$/, ],
	[ 'publisher_name',	1, qr/^Publisher$/, ],
	[ 'publisher_website',	0, qr/^Website$/, ],
	[ 'support_email',	0, qr/^Support E-?mail$/, ],
	[ '_helpline',		0, qr/^Helpline$/, ],
	[ 'url',		0, qr/^Login page$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    stockinvestment =>		{ textname => '', text_out => 'note', fields => [
	[ '_symbol',		1, qr/^Symbol$/, ],
	[ '_accountnum',	0, qr/^Account number$/, ],
	[ '_type',		0, qr/^Type$/, ],
	[ '_market',		1, qr/^Market$/, ],
	[ '_launchedon',	0, qr/^Launched on$/, ],
	[ '_purchasedon',	0, qr/^Purchased on$/, ],
	[ '_purchasedprice',	0, qr/^Purchase price$/, ],
	[ '_quantity',		0, qr/^Quantity$/, ],
	[ '_currentprice',	1, qr/^Current price$/, ],
	[ '_broker',		0, qr/^Broker$/, ],
	[ '_brokerphone',	0, qr/^Phone$/, ],
	[ 'url',		0, qr/^Website$/,		{ type_out => 'login' } ],
	[ 'username',		0, qr/^Username$/,		{ type_out => 'login' } ],
	[ 'password',		0, qr/^Password$/,		{ type_out => 'login' } ],
    ]},
    travellingvisa =>		{ textname => '', type_out => 'note', fields => [
	[ '_type',		0, qr/^Type$/, ],
	[ '_country',		0, qr/^Country$/, ],
	[ '_fullname',		0, qr/^Full name$/, ],
	[ '_number',		0, qr/^Number$/, ],
	[ '_validfor',		1, qr/^Valid for$/, ],
	[ '_validfrom',		0, qr/^Valid from$/, ],
	[ '_validuntil',	1, qr/^Valid until$/, ],
	[ '_duration',		1, qr/^Duration$/, ],
	[ '_numentries',	1, qr/^No\. of entries$/, ],
	[ '_issued_by',		1, qr/^Issued by$/, ],
	[ '_issued_date',	0, qr/^Issue date$/, ],
	[ '_passportnum',	1, qr/^Passport number$/, ],
	[ '_remarks',		1, qr/^Remarks$/, ],
	[ '_iflostcall',	0, qr/^If lost, call$/, ],
    ]},
    webhosting =>		{ textname => '', type_out => 'server', fields => [
	[ 'name',		0, qr/^Provider$/, ],
	[ 'username', 		0, qr/^Username$/, ],
	[ 'password', 		0, qr/^Password$/, ],
	[ 'admin_console_url',	0, qr/^Admin URL$/, ],
	[ '_os',		0, qr/^OS$/, ],
	[ '_customerid',	0, qr/^Customer ID$/, ],
	[ '_http',		1, qr/^HTTP$/, ],
	[ '_ftp',		0, qr/^FTP$/, ],
	[ '_database',		0, qr/^Database$/, ],
	[ '_services',		1, qr/^Services$/, ],
	[ 'support_contact_url',0, qr/^Support website$/, ],
	[ '_helpline',		0, qr/^Helpline$/, ],
	[ '_fee',		1, qr/^Fee$/, ],
    ]},
    wireless =>			{ textname => '', fields => [
	[ 'name',		1, qr/^Station name$/, ],
	[ 'password',		1, qr/^Station password$/, ],
	[ 'network_name',	1, qr/^Network name$/, ],
	[ 'wireless_password',	1, qr/^Network password$/, ],
	[ 'wireless_security',	0, qr/^Security$/, ],
	[ 'airport_id',		1, qr/^Mac\/Airport #$/, ],
	[ 'server',		1, qr/^Server\/IP address$/, ],
	[ '_username',		0, qr/^Username$/, ],
	[ '_password',		0, qr/^Password$/, ],
	[ 'disk_password',	1, qr/^Storage password$/, ],
	[ '_website',		0, qr/^Support website$/, ],
	[ '_billinginfo',	0, qr/^Billing info$/, ],
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [
	      		     [ q{      --dumpcats           # print the export's categories and field quantities },
			       'dumpcats' ],
			   ],
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
    else {
	$n = process_csv($data, \%Cards, $imptypes);
    }
	
    summarize_import('item', $n - 1);
    return \%Cards;
}

sub dumpcats {
    my $decoded = shift;

    my %templates;
    my %templates_count;

    # Get the section name and fields in each entry.
    for my $entry (@{$decoded->{'items'}}) {
	my $key = $entry->{'template_type'};
	my %fields_in_entry;
	my ($section, $section_index) = ('__MAIN', 1);
	for my $field (@{$entry->{'fields'}}) {
	    if ($field->{'type'} eq 'section') {
		$section = $field->{'label'};
		$section_index++;
		next;
	    }
	    # Keep track of the field label, uid and order.
	    $fields_in_entry{join "::", $section_index, $section, $field->{'label'}, $field->{'uid'}, $field->{'order'}}++;
	}

	# Accumulate template data based on the entry values.
	# There should only be a single label/uid/order trio across all entries, so lets verify this.
	for (keys %fields_in_entry) {
	    $templates{$key}{$_} = max($fields_in_entry{$_}, exists $templates{$key}{$_} ? $templates{$key}{$_} : 0);
	}

	$templates_count{$key}++;
    }

    for my $key (sort keys %templates) {
	printf "%s (%d) -----\n", $key, $templates_count{$key};
	for my $label (sort keys %{$templates{$key}}) {
	    printf "    %3d %s %s\n", 
		$templates{$key}{$label},
		$templates{$key}{$label} > 1 ? "*" : " ",
		($label =~ s/^\d+:://r);
	}
    }
}

sub process_json {
    my ($data, $Cards, $imptypes) = @_;
    my %Folders;

    my $decoded = decode_json Encode::encode('UTF-8', $$data);
    exists $decoded->{'items'} or
	bail "Unable to find any items in the Enpass JSON export file";

    # Process any folders
    for my $folder ( exists $decoded->{'folders'} ? @{$decoded->{'folders'}} : () ) {
	$Folders{$folder->{'uuid'}} = $folder->{'title'};
    }

    if ($main::opts{'dumpcats'}) {
	dumpcats($decoded);
	exit;
    }

    my $n = 1;
    for my $entry (@{$decoded->{'items'}}) {
	my (%cmeta, @fieldlist, $section);
	debug "Category ", $entry->{'category'};

	my $template = $entry->{'template_type'};
	my $category = $entry->{'category'};

	$cmeta{'title'} = $entry->{'title'} // 'Untitled';
	push @{$cmeta{'notes'}}, $entry->{'note'};
	push @{$cmeta{'notes'}}, "Enpass Category: " . $category;	# add the original Enpass "category" to notes
	$cmeta{'modified'} = $entry->{'updated_at'};

	if ($entry->{'favorite'} eq "0") {
	    push @{$cmeta{'tags'}}, 'Favorite';
	    $cmeta{'folder'}  = [ 'Favorite' ];
	}
	for my $folder (exists $entry->{'folders'} ? @{$entry->{'folders'}} : ()) {
	    push @{$cmeta{'tags'}}, $Folders{$folder};
	}

	# Modify the field names when they are not unique.  Append the 'uid' value so
	# the card_field_specs matcher can detect the proper field, and the converter
	# does not drop data.
	# XXX Assumption: uid values will not change over time!
	$section = "__MAIN";
	for my $field (@{$entry->{'fields'}}) {
	    if ($field->{'type'} eq 'section') {
		$section = $field->{'label'};
		next;
	    }
	    # see if current field's label exists more than once in all the labels
	    if ((grep { $field->{'label'} eq ($_->{'label'} =~ s/:::.+$//r) } @{$entry->{'fields'}}) > 1) {
		$field->{'label'} = join ':::', $field->{'label'}, $section, $field->{'uid'}	
	    }
	}

	$section = "__MAIN";
	my %address;
	for my $field (@{$entry->{'fields'}}) {
	    if ($field->{'type'} eq 'section') {
		$section = $field->{'label'};
		next;
	    }
	    my $label = $field->{'label'};
	    if ($template eq 'identity.default') {
		# State:::HOME ADDRESS:::145'
		if ($field->{'label'} =~ /^(Street|City|State|Country|ZIP):::HOME ADDRESS/) {
		    $label = lc $1;
		    bail "Unexpected duplicate home address label $label in entry $cmeta{'title'}"	if exists $address{$label};
		    $address{$label} = $field->{'value'}	if $field->{'value'};
		    next;
		}
		else {
		    #$label = join ' ', (ucfirst lc $section), $field->{'label'};
		}
	    }
	    elsif ($template eq 'login.default' and $field->{'type'} eq 'password' and exists $field->{'history'}) {
		for (@{$field->{'history'}}) {
		    push @{$cmeta{'pwhistory'}}, [ $_->{'value'}, $_->{'updated_at'} ];
		}
	    }
	    $label ||= join "_", 'Unlabeled', $field->{'order'};

	    my $value = $field->{'value'};
	    #debug sprintf "%20s => %s\n",  $label, $value || '';
            next if not defined $value or $value eq '';

	    push @fieldlist, [ $label => $value ];
	}
	if (%address) {
	    push @fieldlist, [ 'HOME ADDRESS' => \%address ];
	}

	if (do_common($Cards, \@fieldlist, \%cmeta, $imptypes, $template)) {
	    $n++;
	}
    }

    return $n;
}

sub process_csv {
    my ($data, $Cards, $imptypes) = @_;

    my $csv = Text::CSV->new ({
	    binary => 1,
	    sep_char => ',',
	    eol => "\n",
    });

    my $io = IO::String->new($data);

#    # remove BOM
#    my $bom;
#    (my $nb = read($io, $bom, 1) == 1 and $bom eq "\x{FEFF}") or
#	bail "Failed to read BOM from CSV file: $file\n$!";

    my $column_names;

    my ($n, $rownum) = (1, 1);

    while (my $row = $csv->getline($io)) {
	debug 'ROW: ', $rownum;
	if ($rownum++ == 1 and join('_', @$row) =~ /^Title_(?:Field_Value_)+[.]+_Note$/) {
	    debug "Skipping header row";
	    next;
	}

	my (@fieldlist, %cmeta);
	$cmeta{'title'} = shift @$row;
	$cmeta{'notes'} = pop @$row;
	# Everything that remains in the row is the field data as label/value pairs
	my %labels_found;
	while (my $label = shift @$row) {
	    my $value = shift @$row;

	    # make labels unique - there are many dups
	    if (exists $labels_found{$label}) {
		my $newlabel = join '___', $label, ++$labels_found{$label};
		debug "\tfield: $newlabel => $value (original label: $label)";
		$label = $newlabel
	    }
	    else {
		debug "\tfield: $label => $value";
		$labels_found{$label}++;
	    }
	    push @fieldlist, [ $label => $value ];		# retain field order
	}

	if (do_common($Cards, \@fieldlist, \%cmeta, $imptypes, undef)) {
            $n++;
        }
    }

    if (! $csv->eof()) {
	warn "Unexpected failure parsing CSV: row $n";
    }

    return  $n;
}

sub do_common {
    my ($Cards, $fieldlist, $cmeta, $imptypes, $type) = @_;

    my $itype = find_card_type($fieldlist, $type);

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
    my ($fieldlist, $itype) = @_;

    my $type = 'note';

    # Record type is specified in JSON file, so just need to match the 'textname' from %card_field_specs
    if (defined $itype) {
	if (my @cfs = grep { $card_field_specs{$_}{'textname'} eq $itype } keys %card_field_specs) {
	    debug "\t\ttype '$itype' matched '$cfs[0]'";
	    return $cfs[0];
	}
	debug "\t\ttype '$itype' defaulting to '$type'";
    }
    else {
	for $type (sort by_test_order keys %card_field_specs) {
	    my ($nfound, @found);
	    for my $cfs (@{$card_field_specs{$type}{'fields'}}) {
		next unless $cfs->[CFS_TYPEHINT] and defined $cfs->[CFS_MATCHSTR];
		for (@$fieldlist) {
		    # type hint, requires matching the specified number of fields
		    if ($_->[0] =~ $cfs->[CFS_MATCHSTR]) {
			$nfound++;
			push @found, $_->[0];
			if ($nfound == $cfs->[CFS_TYPEHINT]) {
			    debug sprintf "type detected as '%s' (%s: %s)", $type, pluralize('key', scalar @found), join('; ', @found);
			    return $type;
			}
		    }
		}
	    }
	}

	$type = grep($_->[0] eq 'Password', @$fieldlist) ? 'login' : 'note';

	debug "\t\ttype defaulting to '$type'";
    }

    return $type;
}

# sort logins as the last to check
sub by_test_order {
    return  1 if $a eq 'password';
    return -1 if $b eq 'password';
    return  1 if $a eq 'login';
    return -1 if $b eq 'login';
    $a cmp $b;
}

sub last4 {
    local $_ = shift;
    s/[- ._:]//;
    /(.{4})$/;
    return $1;
}

sub max {
    $_[$_[0] < $_[1]]
}

1;
