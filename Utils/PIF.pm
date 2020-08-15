#
# Copyright 2014 Mike Cappella (mike@cappella.us)

package Utils::PIF;

our @ISA	= qw(Exporter);
our @EXPORT	= qw(create_pif_record create_pif_file add_new_field clone_pif_field get_items_from_1pif typename_to_typekey typeid_to_typename prepare_icon);
#our @EXPORT_OK	= qw();

use v5.14;
use utf8;
use strict;
use warnings;
use diagnostics;

use JSON::PP;
use UUID::Tiny ':std';
use Date::Calc qw(check_date);
use Utils::Utils;
use MIME::Base64;

# Try to include GD library (for icon resizing)
my ($can_GD, $can_ImageMagick);
BEGIN {
    eval "require GD";
    $can_GD = 1 unless $@;
    eval "require Image::Magick";
    $can_ImageMagick = 1 unless $@;
}

# UUID string used by the 1PIF format to separate individual entries.
# DaveT: "You know what, I wish we had thought that far ahead and made this an Easter Egg of sorts.
#         Alas, the truth isn't that exciting :-)"

my $agilebits_1pif_entry_sep_uuid_str = '***5642bee8-a5ff-11dc-8314-0800200c9a66***';

our %typeMap = (
    bankacct =>		{ typeNum => '101', typeName => 'wallet.financial.BankAccountUS',		title => 'Bank Account' },
    bankacctau =>	{ typeNum => undef, typeName => 'wallet.financial.BankAccountAU',		title => 'Bank Account (AU)' },		# not currently supported
    bankacctca =>	{ typeNum => undef, typeName => 'wallet.financial.BankAccountCA',		title => 'Bank Account (CA)' },		# not currently supported
    bankacctch =>	{ typeNum => undef, typeName => 'wallet.financial.BankAccountCH',		title => 'Bank Account (CH)' },		# not currently supported
    bankacctde =>	{ typeNum => undef, typeName => 'wallet.financial.BankAccountDE',		title => 'Bank Account (DE)' },		# not currently supported
    bankacctuk =>	{ typeNum => undef, typeName => 'wallet.financial.BankAccountUK',		title => 'Bank Account (UK)' },		# not currently supported
    creditcard =>	{ typeNum => '002', typeName => 'wallet.financial.CreditCard',			title => 'Credit Card' },
    database =>		{ typeNum => '102', typeName => 'wallet.computer.Database',			title => 'Database' },
    driverslicense =>	{ typeNum => '103', typeName => 'wallet.government.DriversLicense',		title => 'Drivers License' },
    email =>		{ typeNum => '111', typeName => 'wallet.onlineservices.Email.v2',		title => 'Email' },
    dotmac =>		{ typeNum => undef, typeName => 'wallet.onlineservices.DotMac',			title => 'MobileMe' },			# Legacy
    emailv1 =>		{ typeNum => undef, typeName => 'wallet.onlineservices.Email',			title => 'Email (legacy)' },		# Legacy
    ftp =>		{ typeNum => undef, typeName => 'wallet.onlineservices.FTP',			title => 'FTP' },			# Legacy
    genericacct =>	{ typeNum => undef, typeName => 'wallet.onlineservices.GenericAccount',		title => 'Generic Account' },		# Legacy
    instantmessenger =>	{ typeNum => undef, typeName => 'wallet.onlineservices.InstantMessenger',	title => 'Instant Messenger' },		# Legacy
    isp =>		{ typeNum => undef, typeName => 'wallet.onlineservices.ISP',			title => 'Internet Provider' },		# Legacy
    itunes =>		{ typeNum => undef, typeName => 'wallet.onlineservices.iTunes',			title => 'iTunes' },			# Legacy
    amazons3 =>		{ typeNum => undef, typeName => 'wallet.onlineservices.AmazonS3',		title => 'Amazon S3' },			# Legacy
    identity =>		{ typeNum => '004', typeName => 'identities.Identity',				title => 'Identity' },
    login =>		{ typeNum => '001', typeName => 'webforms.WebForm',				title => 'Login' },
    membership =>	{ typeNum => '105', typeName => 'wallet.membership.Membership',			title => 'Membership' },
    note =>		{ typeNum => '003', typeName => 'securenotes.SecureNote',			title => 'Secure Note' },
    outdoorlicense =>	{ typeNum => '104', typeName => 'wallet.government.HuntingLicense',		title => 'Outdoor License' },
    passport =>		{ typeNum => '106', typeName => 'wallet.government.Passport',			title => 'Passport' },
    password =>		{ typeNum => '005', typeName => 'passwords.Password',				title => 'Password' },
    rewards =>		{ typeNum => '107', typeName => 'wallet.membership.RewardProgram',		title => 'Reward Program' },
    server =>		{ typeNum => '110', typeName => 'wallet.computer.UnixServer',			title => 'Server' },
    socialsecurity =>	{ typeNum => '108', typeName => 'wallet.government.SsnUS',			title => 'Social Security Number' },
    software =>		{ typeNum => '100', typeName => 'wallet.computer.License',			title => 'Software License' },
    wireless =>		{ typeNum => '109', typeName => 'wallet.computer.Router',			title => 'Wireless Router' },
);

#    "006": true, // Document


my %typenames_to_typekeys;	# maps typeName --> key from %typeMap above
my %typenums_to_typeNames;	# maps typeNum  --> key from %typeMap above

for (keys %typeMap) {
    $typenames_to_typekeys{$typeMap{$_}{'typeName'}} = $_;
    $typenums_to_typeNames{$typeMap{$_}{'typeNum'}} = $typeMap{$_}{'typeName'}		if defined $typeMap{$_}{'typeNum'};
}

sub typename_to_typekey {
    return $typenames_to_typekeys{$_[0]};
}
sub typeid_to_typename {
    return $typenums_to_typeNames{$_[0]};
}

our $sn_main		= '.';
our $sn_branchInfo	= 'branchInfo.Branch Information';
our $sn_contactInfo	= 'contactInfo.Contact Information';
our $sn_details		= 'details.Additional Details';
our $sn_smtp		= 'SMTP.SMTP';
our $sn_eContactInfo	= 'Contact Information.Contact Information';
our $sn_adminConsole	= 'admin_console.Admin Console';
our $sn_hostProvider	= 'hosting_provider_details.Hosting Provider';
our $sn_customer	= 'customer.Customer';
our $sn_publisher	= 'publisher.Publisher';
our $sn_order		= 'order.Order';
our $sn_extra		= 'extra.More Information';
our $sn_address		= 'address.Address';
our $sn_internet	= 'internet.Internet Details';
our $sn_identity	= 'name.Identification';
# --addfields section name
our $sn_addfields	= 'originalfields.Original Fields';

our $k_string		= 'string';
our $k_menu		= 'menu';
our $k_concealed	= 'concealed';
our $k_date		= 'date';
our $k_gender		= 'gender';
our $k_cctype		= 'cctype';
our $k_monthYear	= 'monthYear';
our $k_phone		= 'phone';
our $k_url		= 'URL';
our $k_email		= 'email';
our $k_address		= 'address';
our $k_totp		= 'totp';		# results in $k_concealed, but triggers generation of string TOTP_<UUID>

my $f_nums		= join('', "0" .. "9");
my $f_alphanums		= join('', $f_nums, "A" .. "Z", "a" .. "z");

my $gFolders		= {};		# global 1PIF folder tree for records mapping UUIDs to folder names

my %pif_table = (
	# n=key                 section			 k=kind         t=text label
    bankacct => [
	[ 'bankName',	 	$sn_main,		$k_string,	'bank name' ], 
	[ 'owner',	 	$sn_main,		$k_string,	'name on account' ], 
	[ 'accountType', 	$sn_main,		$k_menu,	'type' ], 
	[ 'routingNo',	 	$sn_main,		$k_string,	'routing number' ], 
	[ 'accountNo',	 	$sn_main,		$k_string,	'account number' ], 
	[ 'swift',	 	$sn_main,		$k_string,	'SWIFT' ], 
	[ 'iban',	 	$sn_main,		$k_string,	'IBAN' ], 
	[ 'telephonePin',	$sn_main,		$k_concealed,	'PIN',			'generate'=>'off' ],
	[ 'branchPhone',	$sn_branchInfo,   	$k_string,	'phone' ],
	[ 'branchAddress',	$sn_branchInfo,   	$k_string,	'address' ],
    ],
    creditcard => [
	[ 'cardholder',	 	$sn_main,		$k_string,	'cardholder name',	'guarded'=>'yes' ], 
	[ 'type',	 	$sn_main,		$k_cctype,	'type',			'guarded'=>'yes' ], 
	[ 'ccnum',	 	$sn_main,		$k_string,	'number',		'guarded'=>'yes', 'clipboardFilter'=>$f_nums ], 
	[ 'cvv',	 	$sn_main,		$k_concealed,	'verification number',	'guarded'=>'yes', 'generate'=>'off' ], 
	[ 'expiry',	 	$sn_main,		$k_monthYear,	'expiry date',		'guarded'=>'yes' ], 
	[ 'validFrom',	 	$sn_main,		$k_monthYear,	'valid from',		'guarded'=>'yes' ], 
	[ 'bank',	 	$sn_contactInfo,	$k_string,	'issuing bank' ], 
	[ 'phoneLocal',	 	$sn_contactInfo,	$k_phone,	'phone (local)' ], 
	[ 'phoneTollFree', 	$sn_contactInfo,	$k_phone,	'phone (toll free)' ], 
	[ 'phoneIntl',	 	$sn_contactInfo,	$k_phone,	'phone (intl)' ], 
	[ 'website',	 	$sn_contactInfo,	$k_url,		'website' ], 
	[ 'pin',	 	$sn_details,      	$k_concealed,	'PIN',			'guarded'=>'yes' ], 
	[ 'creditLimit', 	$sn_details,      	$k_string,	'credit limit' ], 
	[ 'cashLimit', 		$sn_details,      	$k_string,	'cash withdrawal limit' ], 
	[ 'interest', 		$sn_details,      	$k_string,	'interest rate' ], 
	[ 'issuenumber', 	$sn_details,      	$k_string,	'issue number' ], 
    ],
    database => [
	[ 'database_type', 	$sn_main,		$k_menu,	'type' ], 
	[ 'hostname', 		$sn_main,		$k_string,	'server' ], 
	[ 'port', 		$sn_main,		$k_string,	'port' ], 
	[ 'database', 		$sn_main,		$k_string,	'database' ], 
	[ 'username', 		$sn_main,		$k_string,	'username' ], 
	[ 'password', 		$sn_main,		$k_concealed,	'password' ], 
	[ 'sid', 		$sn_main,		$k_string,	'SID' ], 
	[ 'alias', 		$sn_main,		$k_string,	'alias' ], 
	[ 'options', 		$sn_main,		$k_string,	'connection options' ], 
    ],
    driverslicense => [
	[ 'fullname', 		$sn_main,		$k_string,	'full name' ], 
	[ 'address', 		$sn_main,		$k_string,	'address' ], 
	[ 'birthdate', 		$sn_main,		$k_date,	'date of birth' ], 
    # implement date conversions: explodes into key_dd, key_mm, key_yy; main value stored as integer
	[ 'sex', 		$sn_main,		$k_gender,	'sex' ], 
    # implement gender conversions
	[ 'height', 		$sn_main,		$k_string,	'height' ], 
	[ 'number', 		$sn_main,		$k_string,	'number' ], 
	[ 'class', 		$sn_main,		$k_string,	'license class' ], 
	[ 'conditions', 	$sn_main,		$k_string,	'conditions / restrictions' ], 
	[ 'state', 		$sn_main,		$k_string,	'state' ], 
	[ 'country', 		$sn_main,		$k_string,	'country' ], 
	[ 'expiry_date', 	$sn_main,		$k_monthYear,	'expiry date' ], 
    ],
    email => [
	[ 'pop_type', 		$sn_main,		$k_menu,	'type' ], 
	[ 'pop_username',	$sn_main,		$k_string,	'username' ], 
	[ 'pop_server',		$sn_main,		$k_string,	'server' ], 
	[ 'pop_port',		$sn_main,		$k_string,	'port number' ], 
	[ 'pop_password',	$sn_main,		$k_concealed,	'password' ], 
	[ 'pop_security',	$sn_main,		$k_menu,	'security' ], 
	[ 'pop_authentication',	$sn_main,		$k_menu,	"auth\x{200b} method" ], 
	[ 'smtp_server',	$sn_smtp,		$k_string, 	'SMTP server' ], 
	[ 'smtp_port',		$sn_smtp,		$k_string, 	'port number' ], 
	[ 'smtp_username',	$sn_smtp,		$k_string, 	'username' ], 
	[ 'smtp_password',	$sn_smtp,		$k_concealed,	'password' ], 
	[ 'smtp_security',	$sn_smtp,		$k_menu, 	'security' ], 
	[ 'smtp_authentication',$sn_smtp,		$k_menu, 	"auth\x{200b} method" ], 
    # handle menu types above?
	[ 'provider',		$sn_eContactInfo,	$k_string, 	'provider' ], 
	[ 'provider_website',	$sn_eContactInfo,	$k_string, 	'provider\'s website' ], 
	[ 'phone_local',	$sn_eContactInfo,	$k_string, 	'phone (local)' ], 
	[ 'phone_tollfree',	$sn_eContactInfo,	$k_string, 	'phone (toll free)' ], 
    ],
    identity => [
	[ 'firstname', 		$sn_identity,		$k_string,	'first name',		'guarded'=>'yes' ], 
	[ 'initial', 		$sn_identity,		$k_string,	'initial',		'guarded'=>'yes' ], 
	[ 'lastname', 		$sn_identity,		$k_string,	'last name',		'guarded'=>'yes' ], 
	[ 'sex', 		$sn_identity,		$k_menu,	'sex',			'guarded'=>'yes' ], 
	[ 'birthdate', 		$sn_identity,		$k_date,	'birth date',		'guarded'=>'yes' ], 
	[ 'occupation', 	$sn_identity,		$k_string,	'occupation',		'guarded'=>'yes' ], 
	[ 'company', 		$sn_identity,		$k_string,	'company',		'guarded'=>'yes' ], 
	[ 'department', 	$sn_identity,		$k_string,	'department',		'guarded'=>'yes' ], 
	[ 'jobtitle', 		$sn_identity,		$k_string,	'job title',		'guarded'=>'yes' ], 
	[ 'address', 		$sn_address,		$k_address,	'address',		'guarded'=>'yes' ], 
    # k_address types expand to city, country, state, street, zip
	[ 'defphone', 		$sn_address,		$k_phone,	'default phone',	'guarded'=>'yes' ], 
	[ 'homephone', 		$sn_address,		$k_phone,	'home',			'guarded'=>'yes' ], 
	[ 'cellphone', 		$sn_address,		$k_phone,	'cell',			'guarded'=>'yes' ], 
	[ 'busphone', 		$sn_address,		$k_phone,	'business',		'guarded'=>'yes' ], 
    # *phone expands to *phone_local at top level (maybe due to phone type?)
	[ 'username', 		$sn_internet,		$k_string,	'username',		'guarded'=>'yes' ], 
	[ 'reminderq', 		$sn_internet,		$k_string,	'reminder question',	'guarded'=>'yes' ], 
	[ 'remindera', 		$sn_internet,		$k_string,	'reminder answer',	'guarded'=>'yes' ], 
	[ 'email', 		$sn_internet,		$k_string,	'email',		'guarded'=>'yes' ], 
	[ 'website', 		$sn_internet,		$k_string,	'website',		'guarded'=>'yes' ], 
	[ 'icq', 		$sn_internet,		$k_string,	'ICQ',			'guarded'=>'yes' ], 
	[ 'skype', 		$sn_internet,		$k_string,	'skype',		'guarded'=>'yes' ], 
	[ 'aim', 		$sn_internet,		$k_string,	'AOL/AIM',		'guarded'=>'yes' ], 
	[ 'yahoo', 		$sn_internet,		$k_string,	'Yahoo',		'guarded'=>'yes' ], 
	[ 'msn', 		$sn_internet,		$k_string,	'MSN',			'guarded'=>'yes' ], 
	[ 'forumsig', 		$sn_internet,		$k_string,	'forum signature',	'guarded'=>'yes' ], 
    ],
    login => [
	[ 'username', 		undef,			'T',		'username' ], 
	[ 'password', 		undef,			'P',		'password' ], 
	[ 'url', 		undef,			$k_string,	'website' ], 
	[ '*additionalurls', 	undef,			$k_string,	'' ], 		# Special: not a 1Password defined login template field
	[ '_totp', 		$sn_details,		$k_totp,	'totp' ], 
    ],
    membership => [
	[ 'org_name', 		$sn_main,		$k_string,	'group' ], 
	[ 'website', 		$sn_main,		$k_url,		'website' ], 
	[ 'phone', 		$sn_main,		$k_phone,	'telephone' ], 
	[ 'member_name', 	$sn_main,		$k_string,	'member name' ], 
	[ 'member_since', 	$sn_main,		$k_monthYear,	'member since' ], 
	[ 'expiry_date', 	$sn_main,		$k_monthYear,	'expiry date' ], 
	[ 'membership_no', 	$sn_main,		$k_string,	'member ID' ], 
	[ 'pin', 		$sn_main,		$k_concealed,	'password' ], 
    ],
    note => [
    ],
    outdoorlicense => [
	[ 'name',		$sn_main,		$k_string,	'full name' ], 
	[ 'valid_from',		$sn_main,		$k_date,	'valid from' ], 
	[ 'expires',		$sn_main,		$k_date,	'expires' ], 
	[ 'game',		$sn_main,		$k_string,	'approved wildlife' ], 
	[ 'quota',		$sn_main,		$k_string,	'maximum quota' ], 
	[ 'state',		$sn_main,		$k_string,	'state' ], 
	[ 'country',		$sn_main,		$k_string,	'country' ], 
    ],
    passport => [
	[ 'type', 		$sn_main,		$k_string,	'passport type' ], 
	[ 'issuing_country', 	$sn_main,		$k_string,	'issuing country' ], 
	[ 'number', 		$sn_main,		$k_string,	'number' ], 
	[ 'fullname', 		$sn_main,		$k_string,	'full name' ], 
	[ 'sex', 		$sn_main,		$k_gender,	'sex' ], 
	[ 'nationality',	$sn_main,		$k_string,	'nationality' ], 
	[ 'issuing_authority',	$sn_main,		$k_string,	'issuing authority' ], 
	[ 'birthdate',		$sn_main,		$k_date,	'date of birth' ], 
	[ 'birthplace',		$sn_main,		$k_string,	'place of birth' ], 
	[ 'issue_date',		$sn_main,		$k_date,	'issued on' ], 
	[ 'expiry_date',	$sn_main,		$k_date,	'expiry date' ], 
    ],
    password => [
	[ 'password', 		undef,			'P',		'password' ], 
	[ 'url', 		undef,			$k_string,	'website' ], 
    ],
    rewards => [
	[ 'company_name',	$sn_main,		$k_string,	'company name' ], 
	[ 'member_name',	$sn_main,		$k_string,	'member name' ], 
	[ 'membership_no',	$sn_main,		$k_string,	'member ID',		'clipboardFilter' => $f_alphanums ], 
	[ 'pin',		$sn_main,		$k_concealed,	'PIN' ], 
	[ 'additional_no',	$sn_extra,		$k_string,	'member ID (additional)' ], 
	[ 'member_since',	$sn_extra,		$k_monthYear,	'member since' ], 
	[ 'customer_service_phone',$sn_extra,		$k_string,	'customer service phone' ], 
	[ 'reservations_phone',	$sn_extra,		$k_phone,	'phone for reserva\x{200b}tions' ], 
	[ 'website',		$sn_extra,		$k_url,		'website' ], 
    ],
    server => [
	[ 'url', 		$sn_main,		$k_string,	'URL' ], 
	[ 'username', 		$sn_main,		$k_string,	'username' ], 
	[ 'password', 		$sn_main,		$k_concealed,	'password' ], 
	[ 'admin_console_url', 	    $sn_adminConsole,	$k_string,	'admin console URL' ], 
	[ 'admin_console_username', $sn_adminConsole,	$k_string,	'admin console username' ], 
	[ 'admin_console_password', $sn_adminConsole,	$k_concealed,	'console password' ], 
	[ 'name',		    $sn_hostProvider,	$k_string,	'name' ], 
	[ 'website',		    $sn_hostProvider,	$k_string,	'website' ], 
	[ 'support_contact_url',    $sn_hostProvider,	$k_string,	'support URL' ], 
	[ 'support_contact_phone',  $sn_hostProvider,	$k_string,	'support phone' ], 
    ],
    socialsecurity => [
	[ 'name', 		$sn_main,		$k_string,	'name' ], 
	[ 'number', 		$sn_main,		$k_concealed,	'number',		'generate'=>'off' ], 
    ],
    software => [
	[ 'product_version',	$sn_main,		$k_string,	'version' ], 
	[ 'reg_code',		$sn_main,		$k_string,	'license key',		'guarded'=>'yes', 'multiline'=>'yes' ], 
	[ 'reg_name',		$sn_customer,		$k_string,	'licensed to' ], 
	[ 'reg_email',		$sn_customer,		$k_email,	'registered email' ], 
	[ 'company',		$sn_customer,		$k_string,	'company' ], 
	[ 'download_link',	$sn_publisher,		$k_url,		'download page' ], 
	[ 'publisher_name',	$sn_publisher,		$k_string,	'publisher' ], 
	[ 'publisher_website',	$sn_publisher,		$k_url,		'website' ], 
	[ 'retail_price',	$sn_publisher,		$k_string,	'retail price' ], 
	[ 'support_email',	$sn_publisher,		$k_email,	'support email' ], 
	[ 'order_date',		$sn_order,		$k_date,	'purchase date' ], 
	[ 'order_number',	$sn_order,		$k_string,	'order number' ], 
	[ 'order_total',	$sn_order,		$k_string,	'order total' ], 
    ],
    wireless => [
	[ 'name',		$sn_main,		$k_string,	'base station name' ], 
	[ 'password',		$sn_main,		$k_concealed,	'base station password' ], 
	[ 'server',		$sn_main,		$k_string,	'server / IP address' ], 
	[ 'airport_id',		$sn_main,		$k_string,	'AirPort ID' ], 
	[ 'network_name',	$sn_main,		$k_string,	'network name' ], 
	[ 'wireless_security',	$sn_main,		$k_menu,	'wireless security' ], 
	[ 'wireless_password',	$sn_main,		$k_concealed,	'wireless network password' ], 
	[ 'disk_password',	$sn_main,		$k_concealed,	'attached storage password' ], 
    ],
);

my %country_codes = (
    ad => qr/^ad|Andorra$/i,
    ae => qr/^ae|United Arab Emirates$/i,
    af => qr/^af|Afghanistan$/i,
    ag => qr/^ag|Antigua and Barbuda$/i,
    al => qr/^al|Albania$/i,
    am => qr/^am|Armenia$/i,
    ao => qr/^ao|Angola$/i,
    ar => qr/^ar|Argentina$/i,
    at => qr/^at|Austria$/i,
    au => qr/^au|Australia$/i,
    az => qr/^az|Azerbaijan$/i,
    ba => qr/^ba|Bosnia and Herzegovina$/i,
    bb => qr/^bb|Barbados$/i,
    bd => qr/^bd|Bangladesh$/i,
    be => qr/^be|Belgium$/i,
    bf => qr/^bf|Burkina Faso$/i,
    bg => qr/^bg|Bulgaria$/i,
    bh => qr/^bh|Bahrain$/i,
    bi => qr/^bi|Burundi$/i,
    bj => qr/^bj|Benin$/i,
    bl => qr/^bl|Saint Barthélemy$/i,
    bm => qr/^bm|Bermuda$/i,
    bn => qr/^bn|Brunei Darussalam$/i,
    bo => qr/^bo|Bolivia$/i,
    br => qr/^br|Brazil$/i,
    bs => qr/^bs|The Bahamas$/i,
    bt => qr/^bt|Bhutan$/i,
    bw => qr/^bw|Botswana$/i,
    by => qr/^by|Belarus$/i,
    bz => qr/^bz|Belize$/i,
    ca => qr/^ca|Canada$/i,
    cd => qr/^cd|Democratic Republic of the Congo$/i,
    cf => qr/^cf|Central African Republic$/i,
    cg => qr/^cg|Republic of the Congo$/i,
    ch => qr/^ch|Switzerland$/i,
    ci => qr/^ci|Côte d’Ivoire$/i,
    cl => qr/^cl|Chile$/i,
    cm => qr/^cm|Cameroon$/i,
    cn => qr/^cn|China$/i,
    co => qr/^co|Colombia$/i,
    cr => qr/^cr|Costa Rica$/i,
    cs => qr/^cs|Czech Republic$/i,
    cu => qr/^cu|Cuba$/i,
    cv => qr/^cv|Cape Verde$/i,
    cy => qr/^cy|Cyprus$/i,
    cz => qr/^cz|Czech Republic$/i,
    de => qr/^de|Germany$/i,
    dj => qr/^dj|Djibouti$/i,
    dk => qr/^dk|Denmark$/i,
    dm => qr/^dm|Dominica$/i,
    do => qr/^do|Dominican Republic$/i,
    dz => qr/^dz|Algeria$/i,
    ec => qr/^ec|Ecuador$/i,
    ee => qr/^ee|Estonia$/i,
    eg => qr/^eg|Egypt$/i,
    er => qr/^er|Eritrea$/i,
    es => qr/^es|Spain$/i,
    et => qr/^et|Ethiopia$/i,
    fi => qr/^fi|Finland$/i,
    fj => qr/^fj|Fiji$/i,
    fk => qr/^fk|Falkland Islands$/i,
    fm => qr/^fm|Micronesia$/i,
    fo => qr/^fo|Faroe Islands$/i,
    fr => qr/^fr|France$/i,
    ga => qr/^ga|Gabon$/i,
    gd => qr/^gd|Grenada$/i,
    ge => qr/^ge|Georgia$/i,
    gh => qr/^gh|Ghana$/i,
    gi => qr/^gi|Gibraltar$/i,
    gl => qr/^gl|Greenland$/i,
    gm => qr/^gm|The Gambia$/i,
    gn => qr/^gn|Guinea$/i,
    gp => qr/^gp|Guadeloupe$/i,
    gq => qr/^gq|Equatorial Guinea$/i,
    gr => qr/^gr|Greece$/i,
    gs => qr/^gs|South Georgia and South Sandwich Islands$/i,
    gt => qr/^gt|Guatemala$/i,
    gw => qr/^gw|Guinea-Bissau$/i,
    gy => qr/^gy|Guyana$/i,
    hk => qr/^hk|Hong Kong$/i,
    hn => qr/^hn|Honduras$/i,
    hr => qr/^hr|Croatia$/i,
    ht => qr/^ht|Haiti$/i,
    hu => qr/^hu|Hungary$/i,
    id => qr/^id|Indonesia$/i,
    ie => qr/^ie|Ireland$/i,
    il => qr/^il|Israel$/i,
    im => qr/^im|Isle of Man$/i,
    in => qr/^in|India$/i,
    iq => qr/^iq|Iraq$/i,
    ir => qr/^ir|Iran$/i,
    is => qr/^is|Iceland$/i,
    it => qr/^it|Italy$/i,
    jm => qr/^jm|Jamaica$/i,
    jo => qr/^jo|Jordan$/i,
    jp => qr/^jp|Japan$/i,
    ke => qr/^ke|Kenya$/i,
    kg => qr/^kg|Kyrgyzstan$/i,
    kh => qr/^kh|Cambodia$/i,
    ki => qr/^ki|Kiribati$/i,
    km => qr/^km|Comoros$/i,
    kn => qr/^kn|Saint Kitts and Nevis$/i,
    kp => qr/^kp|North Korea$/i,
    kr => qr/^kr|South Korea$/i,
    kw => qr/^kw|Kuwait$/i,
    ky => qr/^ky|Cayman Islands$/i,
    kz => qr/^kz|Kazakhstan$/i,
    la => qr/^la|Laos$/i,
    lb => qr/^lb|Lebanon$/i,
    lc => qr/^lc|Saint Lucia$/i,
    li => qr/^li|Liechtenstein$/i,
    lk => qr/^lk|Sri Lanka$/i,
    lr => qr/^lr|Liberia$/i,
    ls => qr/^ls|Lesotho$/i,
    lt => qr/^lt|Lithuania$/i,
    lu => qr/^lu|Luxembourg$/i,
    lv => qr/^lv|Latvia$/i,
    ly => qr/^ly|Libya$/i,
    ma => qr/^ma|Morocco$/i,
    mc => qr/^mc|Monaco$/i,
    md => qr/^md|Moldova$/i,
    me => qr/^me|Montenegro$/i,
    mf => qr/^mf|Saint Martin$/i,
    mg => qr/^mg|Madagascar$/i,
    mh => qr/^mh|Marshall Islands$/i,
    mk => qr/^mk|Macedonia$/i,
    ml => qr/^ml|Mali$/i,
    mm => qr/^mm|Myanmar$/i,
    mn => qr/^mn|Mongolia$/i,
    mo => qr/^mo|Macau$/i,
    mq => qr/^mq|Martinique$/i,
    mr => qr/^mr|Mauritania$/i,
    mt => qr/^mt|Malta$/i,
    mu => qr/^mu|Mauritius$/i,
    mv => qr/^mv|Maldives$/i,
    mw => qr/^mw|Malawi$/i,
    mx => qr/^mx|Mexico$/i,
    my => qr/^my|Malaysia$/i,
    mz => qr/^mz|Mozambique$/i,
    na => qr/^na|Namibia$/i,
    nc => qr/^nc|New Caledonia$/i,
    ne => qr/^ne|Niger$/i,
    ng => qr/^ng|Nigeria$/i,
    ni => qr/^ni|Nicaragua$/i,
    nl => qr/^nl|Netherlands$/i,
    no => qr/^no|Norway$/i,
    np => qr/^np|Nepal$/i,
    nr => qr/^nr|Nauru$/i,
    nz => qr/^nz|New Zealand$/i,
    om => qr/^om|Oman$/i,
    pa => qr/^pa|Panama$/i,
    pe => qr/^pe|Peru$/i,
    pf => qr/^pf|French Polynesia$/i,
    pg => qr/^pg|Papua New Guinea$/i,
    ph => qr/^ph|Philippines$/i,
    pk => qr/^pk|Pakistan$/i,
    pl => qr/^pl|Poland$/i,
    pr => qr/^pr|Puerto Rico$/i,
    ps => qr/^ps|Palestinian Territories$/i,
    pt => qr/^pt|Portugal$/i,
    pw => qr/^pw|Palau$/i,
    py => qr/^py|Paraguay$/i,
    qa => qr/^qa|Qatar$/i,
    re => qr/^re|Réunion$/i,
    ro => qr/^ro|Romania$/i,
    rs => qr/^rs|Serbia$/i,
    ru => qr/^ru|Russia$/i,
    rw => qr/^rw|Rwanda$/i,
    sa => qr/^sa|Saudi Arabia$/i,
    sb => qr/^sb|Solomon Islands$/i,
    sc => qr/^sc|Seychelles$/i,
    sd => qr/^sd|Sudan$/i,
    se => qr/^se|Sweden$/i,
    sg => qr/^sg|Singapore$/i,
    sh => qr/^sh|Saint Helena$/i,
    si => qr/^si|Slovenia$/i,
    sk => qr/^sk|Slovakia$/i,
    sl => qr/^sl|Sierra Leone$/i,
    sm => qr/^sm|San Marino$/i,
    sn => qr/^sn|Senegal$/i,
    so => qr/^so|Somalia$/i,
    sr => qr/^sr|Suriname$/i,
    st => qr/^st|Sao Tome and Principe$/i,
    sv => qr/^sv|El Salvador$/i,
    sy => qr/^sy|Syria$/i,
    sz => qr/^sz|Swaziland$/i,
    td => qr/^td|Chad$/i,
    tg => qr/^tg|Togo$/i,
    th => qr/^th|Thailand$/i,
    tj => qr/^tj|Tajikistan$/i,
    tl => qr/^tl|Timor-Leste$/i,
    tm => qr/^tm|Turkmenistan$/i,
    tn => qr/^tn|Tunisia$/i,
    to => qr/^to|Tonga$/i,
    tr => qr/^tr|Turkey$/i,
    tt => qr/^tt|Trinidad and Tobago$/i,
    tv => qr/^tv|Tuvalu$/i,
    tw => qr/^tw|Taiwan$/i,
    tz => qr/^tz|Tanzania$/i,
    ua => qr/^ua|Ukraine$/i,
    ug => qr/^ug|Uganda$/i,
    uk => qr/^uk|United Kingdom$/i,
    us => qr/^us|United States$/i,
    uy => qr/^uy|Uruguay$/i,
    uz => qr/^uz|Uzbekistan$/i,
    va => qr/^va|Vatican$/i,
    vc => qr/^vc|Saint Vincent and the Grenadines$/i,
    ve => qr/^ve|Venezuela$/i,
    vi => qr/^vi|U.S. Virgin Islands$/i,
    vn => qr/^vn|Vietnam$/i,
    vu => qr/^vu|Vanuatu$/i,
    ws => qr/^ws|Samoa$/i,
    ye => qr/^ye|Yemen$/i,
    yu => qr/^yu|Serbia and Montenegro$/i,
    za => qr/^za|South Africa$/i,
    zm => qr/^zm|Zambia$/i,
    zw => qr/^zw|Zimbabwe$/i,
);

my %ordered_sections;
sub create_pif_record {
    my ($type, $cmeta) = @_;

    my $rec = {};
    my @to_notes;
    my $defs = $pif_table{$type};

    $rec->{'title'} = $cmeta->{'title'} // 'Untitled';
    debug "Title: ", $rec->{'title'};

    while (my $f = pop @{$cmeta->{'fields'}}) {
	my @found = grep { $f->{'outkey'} eq $_->[0] } @$defs;

	# Fields not defined in the pif_table go to notes, unless the addfields option is set
	# whereby custom fields will be added to a custom section instead.
	if (not (@found or $main::opts{'addfields'})) {
	    debug "  key test($f->{'outkey'}), Not found";
	    push @to_notes, $f;
	}
	else {
	    bail "Duplicate card key detected - please report: $f->{'outkey'}: ", map {$_->[0] . " "} @found	if @found > 1;
	    push @to_notes, $f		if $f->{'keep'};

	    my $def = $found[0];
	    if (not defined $def) {
		# this is not a 1Password field, but --addfields was specified, so add
		# the record as a custom field.

		$def->[1] = $sn_addfields;
		$def->[2] = $k_string;
		$def->[3] = lc $f->{'inkey'};
	    }

	    debug "  key test($f->{'outkey'}): ", to_string($f->{'value'});
     
	    if ($type eq 'login') {
		if ($f->{'value'} ne '') {
		    if ($f->{'outkey'} eq 'username' or $f->{'outkey'} eq 'password') {
			push @{$rec->{'secureContents'}{'fields'}}, { 
				'designation' => $f->{'outkey'}, name => $def->[3], 'type' => $def->[2], 'value' => $f->{'value'}
			    };
		    }
		}
	    }

	    if ($type eq 'login' or $type eq 'password') {
		if ($f->{'value'} ne '') {
		    if ($f->{'outkey'} eq 'url') {
			unshift @{$rec->{'secureContents'}{'URLs'}}, { 'label' => $def->[3], 'url' => $f->{'value'} };
			# Need to add Location field so that the item appears in 1Password for Windows' extension.
			$rec->{'location'} = $f->{'value'};
		    }
		    elsif ($f->{'outkey'} eq '*additionalurls') {	# support additional URLs
			for (split /\s*[;\n]\s*/, $f->{'value'}) {
			    push @{$rec->{'secureContents'}{'URLs'}}, { 'label' => $def->[3], 'url' => $_ };
			}
		    }
		    elsif ($f->{'outkey'} eq 'password' and $main::opts{'checkpass'}) {
			do_password_check($f->{'value'}, $rec->{'title'}, $type, $cmeta);
		    }
		}
	    }

	    if (my @kv_pairs = type_conversions($def->[2], $f)) {
		# add key/value pairs to top level secureContents.
		while (@kv_pairs) {
		    # Don't add PIF.pm special keys to the top level
		    if ($kv_pairs[0] !~ /^\*/) {
			$rec->{'secureContents'}{$kv_pairs[0]} = $kv_pairs[1];
		    }
		    shift @kv_pairs; shift @kv_pairs;
		}

		# add entry to secureContents.sections when defined
		if (defined $def->[1]) {

		    my $href = { 'n' => $f->{'outkey'}, 'k' => $def->[2], 't' => $def->[3], 'v' => $f->{'value'} };
		    # add any attributes
		    $href->{'a'} = { @$def[4..$#$def] }   if @$def > 4;
		    
		    # a little sanity check to ensure no null or empty string values get output to the 1PIF
		    my @invalid = grep { not defined $href->{$_} or $href->{$_} eq '' } keys %$href;
		    bail "Please report: unexpected undefined value for @invalid, entry $rec->{'title'}"		if @invalid;

		    push @{$rec->{'_sections'}{join '.', 'secureContents', $def->[1]}}, $href;

		    if ($main::opts{'checkpass'} and $href->{'k'} eq $k_concealed and $href->{'t'} =~ /\bpassword$/) {
			do_password_check($href->{'v'}, $rec->{'title'}, $type, $cmeta);
		    }

		    # Special case TOTP entries; these are stored in the 1PIF as 'concealed' but have
		    # their name prefixed with "TOTP_" and ending with a unique UUID.  Revert the type
		    # to 'concealed'.
		    if ($href->{'k'} eq $k_totp) {
			$href->{'n'} = join '_', 'TOTP', new_uuid(); 
			$href->{'k'} = $k_concealed;
		    }
		}
	    }
	    else {
		push @to_notes, $f;			# failed kind conversions
	    }
	}
    }

    # Output the sections in the same order as in the pif_table{$type}
    my $i;
    %ordered_sections = ();
    for (@{$pif_table{$type}}) {
	next unless $_->[1];
	my $sname = join '.', 'secureContents', $_->[1];
	next if exists $ordered_sections{$sname};
	$ordered_sections{$sname} = $i++;
    }

    for (sort bysections keys %{$rec->{'_sections'}}) {
	my (undef, $name, $title) = split /\./, $_;
	my $href = { 'name' => $name, 'title' => $title, 'fields' => $rec->{'_sections'}{$_} };
	push @{$rec->{'secureContents'}{'sections'}}, $href;
    }
    delete $rec->{'_sections'};

    if (exists $cmeta->{'notes'}) {
	$rec->{'secureContents'}{'notesPlain'} = ref($cmeta->{'notes'}) eq 'ARRAY' ? join("\n", @{$cmeta->{'notes'}}) : $cmeta->{'notes'};
	debug "  notes: ", unfold_and_chop $rec->{'secureContents'}{'notesPlain'};
    }

    $rec->{'typeName'} = $typeMap{$type}{'typeName'} // $typeMap{'note'}{'typeName'};

    push @{$rec->{'openContents'}{'tags'}}, ref($cmeta->{'tags'}) eq 'ARRAY' ? (@{$cmeta->{'tags'}}) : $cmeta->{'tags'} if exists $cmeta->{'tags'};
    push @{$rec->{'openContents'}{'tags'}}, split(/\s*,\s*/, $main::opts{'tags'})				     if exists $main::opts{'tags'};
    debug "  tags: ", unfold_and_chop(join('; ', @{$rec->{'openContents'}{'tags'}}))				     if exists $rec->{'openContents'}{'tags'};

    if ($main::opts{'folders'} and exists $cmeta->{'folder'} and @{$cmeta->{'folder'}}) {
	add_to_folder_tree(\$gFolders, @{$cmeta->{'folder'}});
	my $uuid = uuid_from_path(\$gFolders, @{$cmeta->{'folder'}});
	$rec->{'folderUuid'} = $uuid	if defined $uuid;
    }

    # map any remaining fields to notes
    my @n;
    for (@to_notes) {
	my $valuekey = $_->{'keep'} ? 'valueorig' : 'value';
	next if $_->{$valuekey} eq '';
	push @n, join ': ', $_->{'inkey'}, $_->{$valuekey};
	debug " *unmapped card field pushed to notes: $_->{'inkey'}";
    }
    if (@n) {
	$rec->{'secureContents'}{'notesPlain'} = myjoin("\n", @n,
	    (exists $rec->{'secureContents'}{'notesPlain'} and $rec->{'secureContents'}{'notesPlain'} ne '') ? ("\n" . $rec->{'secureContents'}{'notesPlain'}) : undef);
    }

    $rec->{'uuid'} = new_uuid();

    unless ($main::opts{'notimestamps'}) {
	# Adding 0 force's updatedAt and createdAt to be ints, not strings
	$rec->{'updatedAt'} = 0 + $cmeta->{'modified'}	if exists $cmeta->{'modified'} and defined $cmeta->{'modified'};
	$rec->{'createdAt'} = 0 + $cmeta->{'created'}	if exists $cmeta->{'created'}  and defined $cmeta->{'created'};
    }

    # set the icon if one exists
    $rec->{'secureContents'}{'customIcon'} = $cmeta->{'icon'}	if $cmeta->{'icon'};

    if (exists $cmeta->{'pwhistory'}) {
	for (@{$cmeta->{'pwhistory'}}) {
	    push @{$rec->{'secureContents'}{'passwordHistory'}}, { value => $_->[0], time => $_->[1] }
	}
    }

    # for output file comparison testing
    if ($main::opts{'testmode'}) {
	$rec->{'uuid'} = '0';
	$rec->{'createdAt'} = 0	if exists $rec->{'createdAt'};
	$rec->{'updatedAt'} = 0	if exists $rec->{'modified'};
    }

    return encode_json $rec;
}

sub create_pif_file {
    my ($cardlist, $outfile, $types) = @_;

    check_pif_table();		# check the pif table since a module may have added (incorrect) entries via add_new_field()

    # Load the password checking modude only when requested via the --checkpass option
    if ($main::opts{'checkpass'}) {
	eval "require Utils::PwCheck";
	bail "PwCheck module load failure: $@"	if $@;
	Utils::PwCheck::init();
    }

    open my $outfh, ">", $outfile or
	bail "Cannot create 1pif output file: $outfile\n$!";

    my $ntotal = 0;
    for my $type (keys %$cardlist) {
	next if $types and not exists $types->{lc $type};

	my $n;
	for my $card (@{$cardlist->{$type}}) {
	    my $saved_title = $card->{'title'} // 'Untitled';
	    if (my $encoded = create_pif_record($type, $card)) {
		print $outfh $encoded, "\n", $agilebits_1pif_entry_sep_uuid_str, "\n";
		$n++;
	    }
	    else {
		warn "PIF encoding failed for item '$saved_title', type '$type'";
	    }
	}
	$ntotal += $n;
	verbose "Exported $n $type ", pluralize('item', $n);
    }
    verbose "Exported $ntotal total ", pluralize('item', $ntotal);

    if ($gFolders) {
	output_folder_records($outfh, $gFolders, undef);
    }
    close $outfh;

    verbose "You may now import the file $outfile into 1Password"	if $ntotal;
    report_pwcheck_results()	if $main::opts{'checkpass'};
}

sub add_to_folder_tree {
    my ($folder_tree, $folder_name) = (shift, shift);

    return unless defined $folder_name;
    if (exists $$folder_tree->{$folder_name}) {
	add_to_folder_tree(\$$folder_tree->{$folder_name}{'children'}, @_);
    }
    else {
	# create new folder_tree node
	$$folder_tree->{$folder_name}{'children'} = {};
	$$folder_tree->{$folder_name}{'uuid'} = new_uuid();
	if (@_) {
	    add_to_folder_tree(\$$folder_tree->{$folder_name}{'children'}, @_);
	}
    }
}

sub uuid_from_path {
    my $folder_tree = shift;

    while (my $folder_name = shift @_) {
	return undef if ! exists $$folder_tree->{$folder_name};
	if (@_) {
	    $folder_tree = \$$folder_tree->{$folder_name}{'children'};
	}
	else {
	    return $$folder_tree->{$folder_name}{'uuid'};
	}
    }
    return undef;
}

sub output_folder_records {
    my ($outfh, $f, $parent_uuid) = @_;
    return unless defined $f;
    for (keys %$f) {
	my $frec = {
		uuid => $f->{$_}{'uuid'},
		title => $_,
		typeName => 'system.folder.Regular'
	    };
	$frec->{'folderUuid'} = $parent_uuid	if defined $parent_uuid;
	print $outfh encode_json($frec), "\n", $agilebits_1pif_entry_sep_uuid_str, "\n";
	output_folder_records($outfh, $f->{$_}{'children'}, $f->{$_}{'uuid'})	if $f->{$_}{'children'};
    }
}

sub add_new_field {
    # [ 'url',                $sn_main,               $k_string,      'URL' ],
    my ($type, $key, $section, $kind, $text) = (shift, shift, shift, shift, shift);
    #my ($type, $after, $key, $section, $kind, $text) = @_;

    die "add_new_field: unsupported type '$type' in %pif_table"	if !exists $pif_table{$type};
=cut
    # code to add a field after a given field, but doesn't work in 1P
    my $i = 0;
    foreach (@{$pif_table{$type}}) {
	if ($_->[0] eq $after) {
	    last;
	}
	$i++;
    }
    $DB::single = 1;
    splice @{$pif_table{$type}}, $i+1, 0, [$key, $section, $kind, $text];
=cut
    if (!grep {$_->[0] eq $key and $_->[1] eq $section } @{$pif_table{$type}}) {
	push @{$pif_table{$type}}, [$key, $section, $kind, $text, @_];
    }
}

sub clone_pif_field {
    my ($type, $field) = @_;
    my @found = grep { $_->[0] eq $field } @{$pif_table{$type}};
    die "cloned section not found in %pif_table ($type : $field): please report"	unless @found;
    my @copy = @{$found[0]};
    shift @copy;	# don't need to the field key
    return \@copy;
}

# Performs various conversions on key, value pairs, depending upon type=k values.
# Some key/values will be exploded into multiple key/value pairs.
sub type_conversions {
    my ($type, $f) = @_;

    return ()	if not defined $type;

    if ($type eq $k_date and $f->{'value'} !~ /^-?\d+$/) {
	return ();
    }

    if ($type eq $k_gender) {
	return ( $f->{'outkey'} => $f->{'value'} =~ /F/i ? 'female' : 'male' );
    }

    if ($type eq $k_monthYear) {
	# monthYear types are split into two top level keys: keyname_mm and keyname_yy
	# their value is stored as YYYYMM
	# XXX validate the date w/a module?
	if (my ($year, $month) = ($f->{'value'} =~ /^(\d{4})(\d{2})$/)) {
	    if (check_date($year,$month,1)) {					# validate the date
		return ( join('_', $f->{'outkey'}, 'yy') => $year,
			 join('_', $f->{'outkey'}, 'mm') => $month );
	    }
	}
    }
    elsif ($type eq $k_cctype) {
	my %cctypes = (
	    mc		  => qr/(?:master(?:card)?)|\Amc\z/i,
	    visa	  => qr/visa/i,
	    amex	  => qr/american express|amex/i,
	    diners	  => qr/diners club|\Adc\z/i,
	    carteblanche  => qr/carte blanche|\Acb\z/i,
	    discover	  => qr/discover/i,
	    jcb		  => qr/jcb/i,
	    maestro	  => qr/(?:(?:mastercard\s*)?maestro)|\Amm\z/i,
	    visaelectron  => qr/(?:(?:visa\s*)?electron)|\Ave\z/i,
	    laser	  => qr/laser/i,
	    unionpay	  => qr/union\s*pay|\Aup\z/i,
	);

	if (my @matched = grep { $f->{'value'} =~ $cctypes{$_} } keys %cctypes) {
	    return ( $f->{'outkey'} => $matched[0] );
	}
    }
    elsif ($type eq $k_menu) {
	if ($f->{'outtype'} =~ /^(?:bankacct|database|email|identity|wireless)$/) {
	    my %menus = (
		bankacct => {
		    checking		=> qr/checking/i,
		    savings		=> qr/savings/i,
		    loc			=> qr/loc|line of credit/i,
		    atm			=> qr/atm/i,
		    money_market	=> qr/money market|mm/i,
		    other		=> qr/other/i,
		},
		database => {
		    db2			=> qr/db2/i,
		    filemaker		=> qr/filemaker/i,
		    msacces		=> qr/(?:microsoft\s*)?access/i,
		    mssql		=> qr/ms\s*sql\s*se?rve?r?/i,
		    mysql		=> qr/mysql/i,
		    oracle		=> qr/oracle/i,
		    postgresql		=> qr/postgresql/i,
		    sqlite		=> qr/sqlite/i,
		    other		=> qr/other/i,
		},
		email => {
		    # type
		    pop3		=> qr/^pop3?\b/i,
		    imap		=> qr/^imap\b/i,
		    either		=> qr/either/i,
		    # security
		    none		=> qr/none/i,
		    SSL			=> qr/^ssl/i,
		    TLS			=> qr/^tls/i,
		    # authentication
		    # none handled above
		    password		=> qr/password|pw|pass/i,
		    md5_challenge_response => qr/md5|challenge/i,
		    kerberized_pop	=> qr/kerberized|kpop/i,
		    kerberos_v4		=> qr/kerberos.*4/i,
		    kerberos_v5		=> qr/kerberos.*5|gssapi/i,
		    ntlm		=> qr/ntlm/i,
		},
		identity => {
		    male		=> qr/m/i,
		    female		=> qr/f/i,
		},
		wireless => {
		    none		=> qr/none/i,
		    wpa2p		=> qr/wpa2 per/i,
		    wpa2e		=> qr/wpa2 ent/i,
		    wpa			=> qr/^wpa$/i,
		    wep			=> qr/^wep$/i,
		},
	    );

	    if (my @matched = grep { $f->{'value'} =~ $menus{$f->{'outtype'}}{$_} } keys %{$menus{$f->{'outtype'}}}) {
		return ( $f->{'outkey'} => $matched[0] );
	    }
	}
    }
    elsif ($type eq $k_address and $f->{'outkey'} eq 'address') {
	# address is expected to be in hash w/keys: street city state country zip 
	my $h = $f->{'value'};
	# at the top level in secureContents, key 'address1' is used instead of key 'street'
	$h->{'country'} = country_to_code($h->{'country'})	if $h->{'country'} and !exists $country_codes{$h->{'country'}};
	my %ret = ( 'address1' => $h->{'street'}, map { exists $h->{$_} ? ($_ => $h->{$_}) : () } qw/city state zip country/ );
	return %ret;
    }
    else {
	return ( $f->{'outkey'} => $f->{'value'} );
    }

    # unhandled - unmapped items will ultimately go to a card's notes field
    return ();
}

# Do some internal checking that the %pif_table has expected values.
sub check_pif_table {
    my %all_nkeys;
    my %valid_attrs = (
	generate	=> 'off',
	guarded		=> 'yes',
	clipboardFilter	=> [ $f_nums, $f_alphanums ],
	multiline	=> 'yes',
    );

    my $errors;
    for my $type (keys %pif_table) {
	for (@{$pif_table{$type}}) {
	    # report any typos or unsupported attributes/values
	    if (scalar @$_ > 4) {
		my %a = (@$_)[4..$#$_];
		for my $key (keys %a) {
		    if (! exists $valid_attrs{$key}) {
			say "Internal error: unsupported attribute '$key'";
			$errors++;
		    }
		    elsif (! grep { $a{$key} eq $_ } ref($valid_attrs{$key}) eq 'ARRAY' ? @{$valid_attrs{$key}} : ($valid_attrs{$key})) {
			say "Internal error: type $type\{$_->[0]\} has an unsupported attribute value '$a{$key}' for attribute '$key'";
			$errors++;
		    }
		}
	    }
	}
    }

    $errors and die "Errors in pif_table - please report";
}

sub get_items_from_1pif {
    my $file = shift;
    my @items;

    # Be kind - append the data.1pif file name when the user supplied only the 1PIF directory name.
    $file = join '/', $file, 'data.1pif'	if -d $file;
    my $data = slurp_file($file);

    # eliminate any extraneous UTF-8 BOM
    #$data =~ s/^\x{ef}\x{bb}/\x{bf}/; 		#EF BB BF
    $data =~ s/^\x{ef}\x{bb}\x{bf}//;
    utf8::encode($data);

    # reopen the file descriptor reading from $data
    open my $io,  "<:encoding(utf8)", \$data or
	bail "Unable to reopen IO handle as a variable";

    my $line = 0;
    while ($_ = <$io>) {
	chomp $_;
	$line++;
	next if $_ eq $agilebits_1pif_entry_sep_uuid_str;
	next if $_ =~ /"trashed":true[,}]/;		# skip items in the trash
	my $json = decode_json $_;

	### Conversion of 1p4 for Windows 1PIF into standardized 1PIF
	###
	if (exists $json->{'category'} or exists $json->{'details'} or exists $json->{'overview'}) {
	    debug "Decoding 1p4 entry (line: $line): ", $json->{'overview'}{'title'} // 'Untitled';

	    if (exists $json->{'category'}) {
		bail "Unsupported category number $json->{'category'} - please report"	if not defined $typenums_to_typeNames{$json->{'category'}};
		$json->{'typeName'} = $typenums_to_typeNames{$json->{'category'}};
		delete $json->{'category'};
	    }
	    # details section
	    if (exists $json->{'details'}) {
		$json->{'secureContents'} = $json->{'details'};
		delete $json->{'details'};
	    }

	    # overview section
	    if (exists $json->{'overview'}{'title'}) {
		$json->{'title'} = $json->{'overview'}{'title'};
		delete $json->{'overview'}{'title'};
	    }
	    if (exists $json->{'overview'}{'ainfo'}) {
		$json->{'secureContents'}{'notesPlain'} = $json->{'overview'}{'ainfo'};
		delete $json->{'overview'}{'ainfo'};
	    }
	    if (exists $json->{'overview'}) {
		$json->{'openContents'} = $json->{'overview'};
		delete $json->{'overview'};
	    }
	    # created/update mapping
	    for (qw/created updated/) {
		if (exists $json->{$_}) {
		    $json->{$_ . 'At'} = $json->{$_};
		    delete $json->{$_};
		}
	    }

	    # Delete empty key/value pairs
	    for (keys %$json) {
		delete $json->{$_}	if not defined $json->{$_} or $json->{$_} eq '';
	    }
	    if (exists $json->{'openContents'}) {
		for (keys %{$json->{'openContents'}}) {
		    delete $json->{'openContents'}{$_}	if not defined $json->{'openContents'}{$_} or $json->{'openContents'}{$_} eq '';
		}
	    }
	    # Yuck.  1P4 for Windows outputs empty and null values for 'address' types.
	    # These need to be removed so the XML parser doesn't choke.  Unfortunately, this
	    # means splicing out the empty section entries in the various section arrays.
	    if (exists $json->{'secureContents'}) {
		for (keys %{$json->{'secureContents'}}) {
		    delete $json->{'secureContents'}{$_}	if not defined $json->{'secureContents'}{$_} or $json->{'secureContents'}{$_} eq '';
		}
		if (exists $json->{'secureContents'}{'sections'}) {
		    for (my $si = 0; $si < @{$json->{'secureContents'}{'sections'}}; $si++) {
			my $s = $json->{'secureContents'}{'sections'}[$si];
			if (exists $s->{'fields'}) {
			    for (my $fi = 0; $fi < @{$s->{'fields'}}; $fi++) {
				my $f = $s->{'fields'}[$fi];
				if ($f->{'k'} eq 'address') {
				    for my $k (keys %{$f->{'v'}}) {
					delete $f->{'v'}{$k}	if not defined $f->{'v'}{$k} or $f->{'v'}{$k} eq '';
				    }
				    splice @{$s->{'fields'}}, $fi, 1 		if ! keys %{$f->{'v'}};
				}
			    }
			}
			splice @{$json->{'secureContents'}{'sections'}}, $si, 1 		if exists $s->{'fields'} and scalar(@{$s->{'fields'}}) == 0;
		    }
		}
	    }
	}
	### end of 1p4 for Windows mappings
	###
	else {
	    debug "Decoding entry (line: $line): ", $json->{'title'} || 'Untitled';
	}

	for (keys %$json) {
	    delete $json->{$_}		if not defined $json->{$_} or $json->{$_} eq '';
	}

	push @items, $json;
    }

    close $io;
    return \@items
}

sub to_string {
    return $_[0] 	if ref $_[0] eq '';

    return map { join ':', $_, $_[0]->{$_} // '' } keys %{$_[0]};
}

sub country_to_code {
    for (keys %country_codes) {
	if ($_[0] =~ $country_codes{$_}) {
	    debug "\tcountry conversion: $_[0] --> $_";
	    return $_	
	}
    }

    return $_[0];
}

sub new_uuid {
    my $uuid = create_uuid_as_string(UUID::Tiny->UUID_RANDOM());
    $uuid =~ s/-//g;
    return uc $uuid
}

# Prepare an icon to be suitable to the 1PIF
sub prepare_icon {
    my ($type,$data) = @_;

    my $ret;
    if ($can_ImageMagick) {
	#$image = Image::Magick->new(size=>'64x64');
	my $image = Image::Magick->new(magick => $type);
	my $status = $image->BlobToImage($data);
	$image->Resize(geometry=>'64x64>');	# 64x64, but don't enlarge (better quality)
	$ret = $image->ImageToBlob();
    }
    elsif ($can_GD) {
	my $srcimage = GD::Image->new($data);
	my $dstimage = new GD::Image(64,64);

	# resize the image
	$dstimage->copyResized($srcimage,0,0, 0,0, 64,64, $srcimage->width, $srcimage->height);

	if    ($type eq 'JPEG')	{ $ret = $dstimage->jpeg; }
	elsif ($type eq 'PNG')	{ $ret = $dstimage->png; }
	elsif ($type eq 'GIF')	{ $ret = $dstimage->gif; }
	else			{ say "Unsupported icon image type, please report: $type" }
    }
    else {
	bail "The --icon option was specified, but no graphics libraries were found.\n",
	     "Install the Image::Magick or GD modules, or remove the --icon option.";
    }

    return $ret ? encode_base64($ret, '') : undef;
}

my $full_sn_addfields	= join '.', 'secureContents', $sn_addfields;
# sort sections based on pif_table entry
sub bysections {
    return  1 if not exists $ordered_sections{$a};
    return -1 if not exists $ordered_sections{$b};
    return  1 if $a eq $full_sn_addfields;		# sort the section added by --addfields last
    return -1 if $b eq $full_sn_addfields;
    return $ordered_sections{$a} cmp $ordered_sections{$b};
}

# ------------------------------------------------------------------------------------------------
# Code below only used when the --checkpass option has been supplied by the user - $main::opts{'checkpass'}.
# The Utils::PwCheck module is only loaded when this option is supplied.
#
my $pwcheck_ncompromised = 0;
my $pwcheck_tag		 = 'Password Compromised';
sub do_password_check {
    my ($pass, $title, $type, $cmeta) = @_;

    return unless Utils::PwCheck::check_password($pass);

    verbose '!!! ', $pwcheck_tag, ": $typeMap{$type}{'title'} item '$title', password: '$pass'";
    add_tag ($cmeta, $pwcheck_tag);

    $pwcheck_ncompromised++;
}

sub report_pwcheck_results {
    $pwcheck_ncompromised and
	verbose "!!!! $pwcheck_ncompromised passwords were found to be compromised - after you import into 1Password\n",
	    "!!!! see the Tag '$pwcheck_tag'";
}

sub add_tag {
    my $cmeta = shift;

    if (! exists $cmeta->{'tags'}) {
	$cmeta->{'tags'} = [ @_ ];
    }
    elsif (ref($cmeta->{'tags'}) eq 'ARRAY') {
	push @{$cmeta->{'tags'}}, ( @_ );
    }
    else {
	$cmeta->{'tags'} = [ $cmeta->{'tags'}, @_ ];
    }
}

1;
