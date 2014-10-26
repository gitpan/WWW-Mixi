package WWW::Mixi;

use strict;
use Carp ();
use vars qw($VERSION @ISA);

$VERSION = sprintf("%d.%02d", q$Revision: 0.27$ =~ /(\d+)\.(\d+)/);

require LWP::RobotUA;
@ISA = qw(LWP::RobotUA);
require HTTP::Request;
require HTTP::Response;

use LWP::Debug ();
use HTTP::Cookies;
use HTTP::Request::Common;

sub new {
	my ($class, $email, $password, %opt) = @_;
	my $base = 'http://mixi.jp/';

	# ���ץ����ν���
	Carp::croak('WWW::Mixi mail address required') unless $email;
	Carp::croak('WWW::Mixi password required') unless $password;

	# ���֥������Ȥ�����
	my $name = "WWW::Mixi/" . $VERSION;
	my $self = new LWP::RobotUA $name, $email;
	$self = bless $self, $class;
	$self->from($email);
	$self->delay(1/60);

	# �ȼ��ѿ�������
	$self->{'mixi'} = {
		'base'     => $base,
		'email'    => $email,
		'password' => $password,
		'response' => undef,
		'log'      => $opt{'-log'} ? $opt{'-log'} : \&callback_log,
		'abort'    => $opt{'-abort'} ? $opt{'-abort'} : \&callback_abort,
		'rewrite'  => $opt{'-rewrite'} ? $opt{'-rewrite'} : \&callback_rewrite,
	};

	return $self;
}

sub login {
	my $self = shift;
	my $page = 'login.pl';
	my $next = 'home.pl';
	my %form = (
		'email'    => $self->{'mixi'}->{'email'},
		'password' => $self->{'mixi'}->{'password'},
		'next_url' => $self->absolute_url($next),
	);
	# Cookie��ͭ����
	unless ($self->cookie_jar) {
		my $cookie = sprintf('cookie_%s_%s.txt', $$, time);
		$self->cookie_jar(HTTP::Cookies->new(file => $cookie, ignore_discard => 1));
		$self->log("[info] Cookie��ͭ���ˤ��ޤ�����\n");
	}
	# ������
	$self->log("[info] �ƥ����󤷤ޤ���\n", ) if ($self->session);
	my $res  = $self->post($page, %form);
	if ($res->is_success) {
		$self->{'mixi'}->{'refresh'} = ($res->headers->header('refresh') =~ /url=([^ ;]+)/) ? $self->absolute_url($1) : undef;
	} else {
		$self->{'mixi'}->{'refresh'} = undef;
	}
	return (wantarray) ? ($self->session, $res) : $self->session; 
}

sub is_logined {
	my $self = shift;
	return ($self->session) ? 1 : 0;
}

sub is_login_required {
	my $self = shift;
	my $res  = (@_) ? shift : $self->{'mixi'}->{'response'};
	if    (not $res)             { return '�ڡ���������Ǥ��Ƥ��ޤ���'; }
	elsif (not $res->is_success) { return '�ڡ����������������Ƥ��ޤ����' . $res->message . '�ˡ�'; }
	else {
		my $content = $res->content;
		return 0 if ($content !~ /<form[^<>]+action=["']?([^"'\s<>]*)["']?.*?>/);
		return 0 if ($self->absolute_url($1) ne $self->absolute_url('login.pl'));
		return '������˼��Ԥ��ޤ�����'.$1 if ($content =~ /<b><font color=#DD0000>(.*?)<\/font><\/b>/);
		return '������ɬ�פǤ���';
	}
	return 0;
}

sub session {
	my $self = shift;
	return undef unless ($self->cookie_jar);
	my $cookie = $self->cookie_jar->as_string;
	return undef unless ($cookie =~ /^Set-Cookie.*?:.*? BF_SESSION=(.*?);/);
	return $1;
}

sub refresh { return $_[0]->{'mixi'}->{'refresh'}; }

sub get {
	my $self = shift;
	my $url  = shift;
	$url     = $self->absolute_url($url);
	$self->log("[info] GET�᥽�åɤ�\"${url}\"��������ޤ���\n");
	# ����
	$self->login if (not $self->is_logined);                          # ̤��������ϥ�����
	my $res  = $self->request(HTTP::Request->new('GET', $url));       # ����
	$self->log("[info] �ꥯ�����Ȥ���������ޤ�����\n");
	$_ = $self->is_login_required($res);
	$self->log("[error] $_\n") if ($_);
	# ��λ
	$self->{'mixi'}->{'response'} = $res;
	return $res;
}

sub post {
	my $self = shift;
	my $url  = shift;
	$url     = $self->absolute_url($url);
	$self->log("[info] POST�᥽�åɤ�\"${url}\"��������ޤ���\n");
	# �ꥯ�����Ȥ�����
	my @form = @_;
	my $req  = (grep {ref($_) eq 'ARRAY'} @form) ?
	           &HTTP::Request::Common::POST($url, Content_Type => 'form-data', Content => [@form]) : 
	           &HTTP::Request::Common::POST($url, [@form]);
	$self->log("[info] �ꥯ�����Ȥ���������ޤ�����\n");
	# ����
	my $res = $self->request($req);                                                       # ����
	$self->log("[info] �ꥯ�����Ȥ���������ޤ�����\n");
	$_ = $self->is_login_required($res);
	$self->log("[error] $_\n") if ($_);
	# ��λ
	$self->{'mixi'}->{'response'} = $res;
	return $res;
}

sub response {
	my $self = shift;
	return $self->{'mixi'}->{'response'};
}

sub parse_main_menu {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<map name=mainmenu>(.*?)<\/map>/s) {
		$content = $1;
		while ($content =~ s/<area .*?alt=([^\s<>]*?) .*?href=([^\s<>]*?)>//) {
			my $item = { 'link' => $self->absolute_url($2, $base), 'subject' => $self->rewrite($1) };
			push(@items, $item);
		}
	}
	return @items;
}

sub parse_banner {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	while ($content =~ s/<a href=(".*?"|'.*?'|[^<> ]*).*?><img src=["']?([^<>]*?)['"]? border=0 width=468 height=60 alt=["']?([^<>]*?)['"]?><\/a>//is) {
		my ($link, $image, $subject) = ($1, $2, $3);
		$link = $1 if ($link =~ /^"(.*?)"$/ or /^'(.*?)'$/);
		$link = $self->absolute_url($link, $base);
		$image = $self->absolute_url($image, $base);
		$subject = $self->rewrite($subject);
		my $item = { 'link' => $link, 'image' => $image, 'subject' => $subject };
		push(@items, $item);
	}
	return @items;
}

sub parse_tool_bar {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<td><img src=http:\/\/img.mixi.jp\/img\/b_left.gif WIDTH=22 HEIGHT=23><\/td>(.*?)<td><img src=http:\/\/img.mixi.jp\/img\/b_right.gif WIDTH=23 HEIGHT=23><\/td>/s) {
		$content = $1;
		while ($content =~ s/<a HREF=([^<> ]*?) .*?><img .*?ALT=([^<> ]*?) .*?><\/a>//) {
			my $item = { 'link' => $self->absolute_url($1, $base), 'subject' => $self->rewrite($2) };
			push(@items, $item);
		}
	}
	return @items;
}

sub parse_information {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<!-- start: ���Τ餻 -->(.*?)<\/table>/s) {
		$content = $1;
		$content =~ s/[\r\n]//g;
		$content =~ s/<!--.*?-->//g;
		while ($content =~ s/<tr><td>(.*?)<\/td><td>(.*?)<\/td><td>(.*?)<\/td><\/tr>//i) {
			my ($subject, $linker) = ($1, $3);
			$subject =~ s/\s*<.*?>\s*//g;
			$subject =~ s/^��//;
			my ($link, $description) = ($1, $2) if ($linker =~ /<a href=(.*?) .*?>(.*?)<\/a>/i);
			my $item = {
				'subject'     => $self->rewrite($subject),
				'link'        => $self->absolute_url($link, $base),
				'description' => $self->rewrite($description)
			};
			push(@items, $item);
		}
	}
	return @items;
}

sub parse_calendar {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my %icons   = ('i_sc-.gif' => 'ͽ��', 'i_bd.gif' => '������', 'i_iv1.gif' => '���å��٥��', 'i_iv2.gif' => '���٥��');
	my @items   = ();
	my $term    = $self->parse_calendar_term($res) or return undef; 
	if ($content =~ /<table width="670" border="0" cellspacing="1" cellpadding="3">(.+?)<\/table>/s) {
		$content = $1;
		$content =~ s/<tr ALIGN=center BGCOLOR=#FFF1C4>.*?<\/tr>//is;
		while ($content =~ s/<td HEIGHT=65 [^<>]*><font COLOR=#996600>(\S*?)<\/font>(.*?)<\/td>//is) {
			my $date = $1;
			my $text = $2;
			next unless ($date =~ /(\d+)/);
			$date = sprintf('%04d/%02d/%02d', $term->{'year'}, $term->{'month'}, $1);
			my @events = split(/<br>/, $text);
			foreach my $event (@events) {
				my $item = {};
				if ($event =~ /<img SRC=(.*?) WIDTH=16 HEIGHT=16 ALIGN=middle><a HREF=(.*?)>(.*?)<\/a>/) {
					$item = { 'subject' => $1, 'link' => $2, 'name' => $3, 'time' => $date, 'icon' => $1};
				} elsif ($event =~ /<a href=".*?" onClick="MM_openBrWindow\('(view_schedule.pl\?id=\d+)'.*?\)"><img src=(.*?) .*?>(.*?)<\/a>/) {
					$item = { 'subject' => $2, 'link' => $1, 'name' => $3, 'time' => $date, 'icon' => $2};
				} else {
					next;
				}
				$item->{'subject'} = ($item->{'subject'} =~ /([^\/]+)$/ and $icons{$1}) ? $icons{$1} : "����($1)";
				$item->{'link'} = $self->absolute_url($item->{'link'}, $base);
				$item->{'icon'} = $self->absolute_url($item->{'icon'}, $base);
				push(@items, $item);
			}
		}
	}
	return @items;
}

sub parse_calendar_term {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return unless ($content =~ /<a href="calendar.pl\?year=(\d+)&month=(\d+)&pref_id=13">[^&]*?<\/a>/);
	return {'year' => $1, 'month' => $2};
}

sub parse_calendar_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return undef unless ($content =~ /<a href="(calendar.pl\?.*?)">([^<>]+?)&nbsp;&gt;&gt;/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $subject};
	return $next;
}

sub parse_calendar_previous {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return undef unless ($content =~ /<a href="(calendar.pl\?.*?)">&lt;&lt;&nbsp;([^<>]+)/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $subject};
	return $next;
}

sub parse_diary {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '<td ALIGN=center ROWSPAN=2 NOWRAP WIDTH=95 bgcolor=#FFD8B0>(\d{4})ǯ(\d{2})��(\d{2})��<br>(\d{1,2}):(\d{2})</td>';
	my $re_subj = '<td BGCOLOR=#FFF4E0 WIDTH=430>&nbsp;(.+?)</td>';
	my $re_desc = '<td CLASS=h12>(.+?)</td>';
	my $re_c_date = '<td rowspan="2" align="center" width="95" bgcolor="#f2ddb7" nowrap>\n(\d{4})ǯ(\d{2})��(\d{2})��<br>(\d{1,2}):(\d{2})<br>';
	my $re_link   = '<a href="?(.+?)"?>(.+?)<\/a>';

	if ($content =~ s/<tr VALIGN=top>.*?${re_date}.*?${re_subj}.*?${re_desc}(.+)//is) {
		my $time = sprintf('%04d/%02d/%02d %02d:%02d', $1,$2,$3,$4,$5);
		my $subj = $6;
		my $desc = $7;
		my $comm = $8;
		my @comments=();
		while ($comm =~ s/.*?${re_c_date}.*?${re_link}.*?${re_desc}.*?<\/table>//is){
			my $comm_time = sprintf('%04d/%02d/%02d %02d:%02d', $1,$2,$3,$4,$5);
			my $link = $self->absolute_url($6, $base);
			my $person = $7 ;
			my $comment = $8;
			push( @comments, {'time'=>$comm_time,'link'=>$link,'person'=>$person,'comment'=>$comment});
		}
		push(@items, {'time' => $time, 'description' => $desc, 'subject' => $subj, 'comments'=>\@comments});
	}
	return @items;
}

sub parse_list_bookmark {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>(.+?)<!--�եå�-->/s) {
		$content = $1;
		while ($content =~ s/<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=550>(.*?)<\/table>//is) {
			my $record = $1;
			my @lines = ($record =~ /<tr.*?>(.*?)<\/tr>/gis);
			my $item = {};
			# parse record
			($item->{'link'}, $item->{'image'})  = ($1, $2) if ($lines[0] =~ /<td WIDTH=90 .*?><a href="([^"]*show_friend.pl\?id=\d+)"><img SRC="([^"]*)".*?>/is);
			($item->{'subject'}, $item->{'gender'}) = ($1, $2) if ($lines[0] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?) \((.*?)\)<\/td>/is);
			$item->{'descrption'} = $1 if ($lines[1] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
			$item->{'time'}    = $1 if ($lines[2] =~ /<td BGCOLOR=#FFFFFF WIDTH=140>(.*?)<\/td>/is);
			# format
			foreach (qw(image link)) { $item->{$_} = $self->absolute_url($item->{$_}, $base) if ($item->{$_}); }
			foreach (qw(subject descrption gender)) {
				$item->{$_} =~ s/<.*?>//g if ($item->{$_});
				$item->{$_} = $self->rewrite($item->{$_});
			}
			$item->{'time'} = $self->convert_login_time($item->{'time'}) if ($item->{'time'});
			push(@items, $item) if ($item->{'subject'} and $item->{'link'});
		}
	}
	return @items;
}

sub parse_list_comment {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_list_community {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>(.+?)<\/table>/s) {
		$content = $1;
		while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is) {
			my ($image_part, $text_part) = ($1, $2);
			my @images = ($image_part =~ /<td WIDTH=20% HEIGHT=100 background=http:\/\/img.mixi.jp\/img\/bg_line.gif>(.*?)<\/td>/gi);
			my @texts  = ($text_part =~ /<td>(.*?)<\/td>/gi);
			for (my $i = 0; $i < @images or $i < @texts; $i++) {
				my $item = {};
				my ($image, $text) = ($images[$i], $texts[$i]);
				($item->{'subject'}, $item->{'count'}) = ($1, $2) if ($text =~ /^\s*(.*?)\((\d+)\)\s*$/);
				($item->{'link'},    $item->{'image'}) = ($1, $2) if ($image =~ /<a href=(.*?)><img SRC=(.*?) border=0><\/a>/);
				if ($item->{'link'}) {
					$item->{'subject'} = $self->rewrite($item->{'subject'});
					$item->{'link'}    = $self->absolute_url($item->{'link'}, $base);
					$item->{'image'}   = $self->absolute_url($item->{'image'}, $base);
					push(@items, $item);
				}
			}
		}
	}
	return @items;
}

sub parse_list_community_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return undef unless ($content =~ /<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=580 BGCOLOR=#F8A448>.*?<a href=([^<>]*?)>([^<>]*?)<\/a><\/td>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_community_previous {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return undef unless ($content =~ /<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=580 BGCOLOR=#F8A448>.*?<td ALIGN=right BGCOLOR=#EED6B5><a href=["']?(.+?)['"]?>([^<>]+)<\/a>/);
	my $subject  = $2;
	my $link     = $self->absolute_url($1, $base);
	my $previous = {'link' => $link, 'subject' => $2};
	return $previous;
}

sub parse_list_diary {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '<font COLOR=#996600>(\d{2})��(\d{2})��<br>(\d{1,2}):(\d{2})</font>';
	my $re_subj = '<td bgcolor=#F2DDB7>&nbsp;(.+?)</td>';
	my $re_desc = '<td CLASS=h120>\n(.*?)\n(.+?)\n<br>\n\n</td>';
	my $re_name = '\((.*?)\)';
	my $re_link = '<a href="?(.+?)"?>������\((\d+)\)<\/a>';
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=3 WIDTH=525>(.+)<\/table>/s) {
		$content = $1 ;
		while ($content =~ s/<tr VALIGN=top>.*?${re_date}.*?${re_subj}.*?${re_desc}.*?${re_link}.*?<\/tr>//is) {
			my $time     = sprintf('%02d/%02d %02d:%02d', $1, $2, $3, $4);
			my ($subj, $thumbs, $desc, $link, $count) = ($5, $6, $7, $8, $9);
			$subj = $self->rewrite($subj);
			$desc = $self->rewrite($desc);
			$desc =~ s/^$//g;
			$link = $self->absolute_url($link, $base);
			my @images = ();
			while ($thumbs =~ s/MM_openBrWindow\('(.*?)',.+?<img src=["']?([^<>]*?)['"]? border//is){
				my $img      = $self->absolute_url($1, $base);
				my $thumbimg = $self->absolute_url($2, $base);
				push(@images,  {'thumb_link' => $thumbimg, 'link' => $img});
			}
			push(@items, {'time' => $time, 'description' => $desc, 'subject' => $subj, 'link' => $link, 'count' => $count, 'images' => [@images]});
		}
	}
	return @items;
}

sub parse_list_diary_capacity {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return undef unless ($content =~ /<table width="165" border="0" cellspacing="1" cellpadding="2">(.*?)<\/table>/is);
	my $box      = $1;
	return undef unless ($box =~ /(\d+\.\d+).*?MB\/.*?(\d+\.\d+).*?MB/);
	my $capacity = {'used' => $1, 'max' => $2};
	return $capacity;
}

sub parse_list_diary_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return undef unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5>.*?<a href=([^<>]*?list_diary.pl[^<>]*?)>([^<>]*?)<\/a><\/td>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_diary_previous {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return undef unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5><a href=([^<>]*?list_diary.pl[^<>]*?)>([^<>]*?)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_friend {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	my %status_icons = (
		'http://img.mixi.jp/img/new6.gif' => '���� - new!!',
	);
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>(.+?)<\/table>/s) {
		$content = $1 ;
		while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is) {
			my ($image_part, $text_part) = ($1, $2);
			my @images = ($image_part =~ /<td WIDTH=20% HEIGHT=100 background=http:\/\/img.mixi.jp\/img\/bg_line.gif>(.*?)<\/td>/gi);
			my @texts  = ($text_part =~ /<td>(.*?)<\/td>/gi);
			for (my $i = 0; $i < @images or $i < @texts; $i++) {
				my $item = {};
				my ($image, $text) = ($images[$i], $texts[$i]);
				($item->{'subject'}, $item->{'count'}) = ($1, $2) if ($text =~ /^\s*(.+?)\((\d+)\)/);
				($item->{'link'},    $item->{'image'}) = ($1, $2) if ($image =~ /<a href=(.*?)><img SRC=(.*?) border=0><\/a>/);
				$item->{'status'} = $status_icons{$1} if ($text =~ /<img src=["']?([^\s'"<>]+)/);
				if ($item->{'link'}) {
					$item->{'subject'} = $self->rewrite($item->{'subject'});
					$item->{'link'}    = $self->absolute_url($item->{'link'}, $base);
					$item->{'id'}      = $2 if ($item->{'link'} =~ /(.*?)?id=(\d*)/); 
					$item->{'image'}   = $self->absolute_url($item->{'image'}, $base);
					push(@items, $item);
				}
			}
		}
	}
	return @items;
}

sub parse_list_friend_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return undef unless ($content =~ /\|<\/font>&nbsp;<a HREF=([^<>]*?list_friend.pl[^<>]*?)>([^<>]*?)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_friend_previous {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return undef unless ($content =~ /<a HREF=([^<>]*?list_friend.pl[^<>]*?)>([^<>]*?)<\/a>&nbsp;<font COLOR=[^<>]*?>\|/);
	my $subject  = $2;
	my $link     = $self->absolute_url($1, $base);
	my $previous = {'link' => $link, 'subject' => $2};
	return $previous;
}

sub parse_list_message {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	my $base      = $res->request->uri->as_string;
	my $content   = $res->content;
	my @items     = ();
	my $img_rep   = $self->absolute_url('img/mail5.gif', $base);
	my %emvelopes = (
		$self->absolute_url('img/mail1.gif', $base) => 'new',
		$self->absolute_url('img/mail2.gif', $base) => 'opened',
		$self->absolute_url('img/mail5.gif', $base) => 'replied',
	);
	my $re_link   = '<a href="?(.+?)"?>(.+?)<\/a>';
	if ($content =~ /<!--����Ȣ����-->.*?<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=553>(.+?)<\/table>/s) {
		$content = $1;
		while ($content =~ s/<tr BGCOLOR="(#FFF7E1|#FFFFFF)">(.*?)<\/tr>//s) {
			my $message  = $2;
			my $emvelope = ($message =~ s/<td[^<>]*>\s*<img SRC="(.*?)".*?>\s*<\/td>//s) ? $self->absolute_url($1, $base) : undef;
			my $status   = $emvelopes{$emvelope} ? $emvelopes{$emvelope} : 'unknown';
			if ($message =~ /<td>([^<>]*?)<\/td>\s*<td>${re_link}<\/td>\s*<td>(\d{2})��(\d{2})��<\/td>/is) {
				my ($name, $link, $subj) = ($1, $2, $3);
				my $time = sprintf('%02d/%02d', $4, $5);
				my $item = {
					'time'     => $time,
					'subject'  => $self->rewrite($subj),
					'name'     => $self->rewrite($name),
					'link'     => $self->absolute_url($link, $base),
					'status'   => $status,
					'emvelope' => $emvelope,
				};
				push(@items, $item);
			}
		}
	}
	return @items;
}

sub parse_new_album {
	my $self    = shift;
	return $self->parse_standard_history2(@_);
}

sub parse_new_bbs {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_new_comment {
	my $self    = shift;
	return $self->parse_standard_history2(@_);
}

sub parse_new_friend_diary {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_new_friend_diary_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	return undef unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5>[^\r\n]*?<a href=["']?(.+?)['"]?>([^<>]+)<\/a><\/td><\/tr>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_new_friend_diary_previous {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return undef unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5><a href=["']?(.+?)['"]?>([^<>]+)<\/a>[^\r\n]*?<\/td><\/tr>/);
	my $subject  = $2;
	my $link     = $self->absolute_url($1, $base);
	my $previous = {'link' => $link, 'subject' => $2};
	return $previous;
}

sub parse_new_review {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_self_id {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my $self_id = ($content =~ /<form action="list_review.pl\?id=(\d+)" method=post>/) ? $1 : 0;
	return $self_id;
}

# =item @items = $mixi->parse_show_friend( [$response] );
# 
# �ץ�ե������show_friend.pl�Υᥤ�����ˤ���Ϥ����������Ȥ��֤��ޤ���
# �֤��ͤϡ��ʲ��Τ褦�ʥϥå����ե���󥹤Ǥ���
# 
#  {
#  	'link' => 'http://mixi.jp/show_friend.pl?id=xxxxx',
#  	'name' => '��������',
#  	'time' => '2004/08/18 13:18'
#  }
# 
# =cut

sub parse_show_friend {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my $profile = {};
	my $re_link = '<a href="?(.+?)"?>(.+?)<\/a>';
	return unless ($content =~ s/<!--�ץ�ե�����-->(.+?)<!--�ץ�ե����뤳���ޤ�-->/$1/s);
	return unless ($content =~ s/<table BORDER=0 CELLSPACING=0 CELLPADDING=1 BGCOLOR=#D3B16D>(.+?)<!-- start: diary_new -->/$1/si);
	while ($content =~ s/<tr BGCOLOR=#FFFFFF>\s*<td [^<>]*>(.*?)<\/td>\s*<td [^<>]*>(.*?)<\/td><\/tr>//is) {
		my ($key, $val) = ($1, $2);
		$key =~ s/&nbsp;//g;
		$val =~ s/<br>/\n/g;
		$val =~ s/$re_link/$1/g;
		$val = $self->rewrite($val);
		$profile->{$key} = $val;
	}
	return $profile if (keys(%{$profile}));
	return;
}

sub parse_show_log {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '(\d{4})ǯ(\d{2})��(\d{2})�� (\d{1,2}):(\d{2})';
	my $re_link = '<a href="?(.+?)"?>(.+?)<\/a>';
	if ($content =~ /<table BORDER=0 CELLSPACING=0 CELLPADDING=5>(.+?)<\/table>/s) {
		$content = $1 ;
		while ($content =~ s/${re_date} ${re_link}<br>//is) {
			my $time = sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $4, $5);
			my $name = $self->rewrite($7);
			my $link = $self->absolute_url($6, $base);
			push(@items, {'time' => $time, 'name' => $name, 'link' => $link});
		}
	}
	return @items;
}

sub parse_show_log_count {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my $count   = ($content =~ /�ڡ������ΤΥ�����������<b>(\d+)<\/b> ��������/) ? $1 : 0;
	return $count;
}

sub parse_view_message {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	my $base      = $res->request->uri->as_string;
	my $content   = $res->content;
	my $item      = undef;
	my $re_link   = '<a href="?(.+?)"?>(.+?)<\/a>';
	my $re_date   = '(\d{4})ǯ(\d{2})��(\d{2})��&nbsp;&nbsp;(\d{1,2}):(\d{2})';
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=555>(.*?)<\/table>/s) {
		my $message = $1;
		my @rows = split(/<\/tr>/, $message, 4);
		my $image = $1 if ($rows[0] =~ s/<td ALIGN=center.*?>.*?<img SRC="(.*?)" border=0>.*?<\/td>//i);
		my ($link, $name) = ($1, $2) if ($rows[0] =~ s/<td BGCOLOR=#FFF4E0.*?>.*?${re_link}.*?<\/td>//i);
		my $time = sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $4, $5) if ($rows[1] =~ /${re_date}/);
		my $subj = $1 if ($rows[2] =~ /<\/font>&nbsp;:&nbsp;(.*)<\/td>/);
		my $desc = $1 if ($rows[3] =~ /<td CLASS=h120>(.*?)<\/td>/);
		unless (grep { not $_ } ($image, $link, $name, $time, $subj, $desc)) {
			$item = {
				'subject' => $self->rewrite($subj),
				'time' => $time,
				'name' => $self->rewrite($name),
				'link' => $self->absolute_url($link, $base),
				'image' => $self->absolute_url($image, $base),
				'description' => $self->rewrite($desc),
			};
		}
	}
	return $item;
}

sub parse_view_message_form {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	my $base      = $res->request->uri->as_string;
	my $content   = $res->content;
	my @items     = ();
	while ($content =~ s/<form action="(.*?)"[^<>]*>(.*?)<\/form>//s) {
		my $action = $1;
		my $submit = $2;
		$submit = ($submit =~ /<input TYPE=submit VALUE="(.*?)".*?>/) ? $1 : undef;
		my $command = $1 if ($action =~ /([^\/\?]+)\.pl(\?[^\/]*)?$/);
		my $item = {
			'action' => $self->absolute_url($action),
			'submit' => $submit,
			'command' => $command,
		};
		push(@items, $item);
	}
	return @items;
}

sub parse_add_diary_preview {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<!--���ܥ���-->(.*?)<!--���ܥ���-->/is) {
		$content = $1;
		while ($content =~ s/<form action="([^<>]*?)" method=post>(.*?)<\/form>//is) {
			my $value = {'__action__' => $self->absolute_url($1, $base)};
			my $form = $2;
			foreach my $field (qw(submit diary_title diary_body packed)) {
				$value->{$field} = ($form =~ /<input type=hidden name=${field} value="?(.*?)"?>/) ? $self->rewrite($1) : undef;
			}
			push(@items, $value);
		}
	}
	return @items;
}

sub get_main_menu {
	my $self = shift;
	my $url  = (@_) ? shift : undef;
	if ($url) {
		$self->set_response($url, @_) or return;
	} else {
		return unless ($self->response);
		return unless ($self->response->is_success);
	}
	return $self->parse_main_menu();
}

sub get_banner {
	my $self = shift;
	my $url  = (@_) ? shift : undef;
	if ($url) {
		$self->set_response($url, @_) or return;
	} else {
		return unless ($self->response);
		return unless ($self->response->is_success);
	}
	return $self->parse_banner();
}

sub get_tool_bar {
	my $self = shift;
	my $url  = (@_) ? shift : undef;
	if ($url) {
		$self->set_response($url, @_) or return;
	} else {
		return unless ($self->response);
		return unless ($self->response->is_success);
	}
	return $self->parse_tool_bar();
}

sub get_information {
	my $self = shift;
	my $url  = 'home.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_information();
}

sub get_calendar {
	my $self = shift;
	my $url  = 'calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_calendar();
}

sub get_calendar_term {
	my $self = shift;
	my $url  = 'calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_calendar_term();
}

sub get_calendar_next {
	my $self = shift;
	my $url  = 'calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_calendar_next();
}

sub get_calendar_previous {
	my $self = shift;
	my $url  = 'calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_calendar_previous();
}

sub get_list_bookmark {
	my $self = shift;
	my $url  = 'list_bookmark.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_bookmark();
}

sub get_list_comment {
	my $self = shift;
	my $url  = 'list_comment.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_comment();
}

sub get_list_community {
	my $self = shift;
	my $url  = 'list_community.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_community();
}

sub get_list_community_next {
	my $self = shift;
	my $url  = 'list_community.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_community_next();
}

sub get_list_community_previous {
	my $self = shift;
	my $url  = 'list_community.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_community_previous();
}

sub get_list_diary {
	my $self = shift;
	my $url  = 'list_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_diary();
}

sub get_list_diary_capacity {
	my $self = shift;
	my $url  = 'list_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_diary_capacity();
}

sub get_list_diary_next {
	my $self = shift;
	my $url  = 'list_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_diary_next();
}

sub get_list_diary_previous {
	my $self = shift;
	my $url  = 'list_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_diary_previous();
}

sub get_list_friend {
	my $self = shift;
	my $url  = 'list_friend.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_friend();
}

sub get_list_friend_next {
	my $self = shift;
	my $url  = 'list_friend.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_friend_next();
}

sub get_list_friend_previous {
	my $self = shift;
	my $url  = 'list_friend.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_friend_previous();
}

sub get_list_message {
	my $self = shift;
	my $url  = 'list_message.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_message();
}

sub get_new_album {
	my $self = shift;
	my $url  = 'new_album.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_album();
}

sub get_new_bbs {
	my $self = shift;
	my $url  = 'new_bbs.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_bbs();
}

sub get_new_comment {
	my $self = shift;
	my $url  = 'new_comment.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_comment();
}

sub get_new_friend_diary {
	my $self = shift;
	my $url  = 'new_friend_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_friend_diary();
}

sub get_new_friend_diary_next {
	my $self = shift;
	my $url  = 'new_friend_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_friend_diary_next();
}

sub get_new_friend_diary_previous {
	my $self = shift;
	my $url  = 'new_friend_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_friend_diary_previous();
}

sub get_new_review {
	my $self = shift;
	my $url  = 'new_review.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_review();
}

sub get_self_id {
	my $self = shift;
	my $url  = 'list_review.pl';
	$self->set_response($url, @_) or return;
	return $self->parse_self_id();
}

sub get_show_log {
	my $self = shift;
	my $url  = 'show_log.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_show_log();
}

sub get_show_log_count {
	my $self = shift;
	my $url  = 'show_log.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_show_log_count();
}

sub get_view_message {
	my $self = shift;
	my $url  = shift or return undef;
	$self->set_response($url, @_) or return undef;
	return $self->parse_view_message();
}

sub get_view_message_form {
	my $self = shift;
	my $url  = shift or return;
	$self->set_response($url, @_) or return;
	return $self->parse_view_message_form();
}

sub get_add_diary_preview {
	my $self        = shift;
	my %form        = @_;
	$form{'submit'} = 'main';
	my $response    = $self->post_add_diary(%form);
	return if ($@ or not $response);
	return $self->parse_add_diary_preview();
}

sub get_add_diary_confirm {
	my $self  = shift;
	my %form  = @_;
	my $url   = 'add_diary.pl';
	my @files = qw(photo1 photo2 photo3);
	# �̿�������Хץ�ӥ塼���
	if (grep { $form{$_} } @files) {
		my @items = eval '$self->get_add_diary_preview(%form)';
		@items = grep {$_->{'submit'} eq 'confirm'} @items;
		return 0 unless (@items);
        $form{'packed'} = $items[0]->{'packed'};
	}
	# ���
	$form{'submit'} = 'confirm';
	my $response = eval '$self->post_add_diary(%form)';
	return 0 if ($@ or not $response);
	return $response->is_success;
}

sub get_edit_diary_confirm {
	my $self  = shift;
	my %form  = @_;
	my $url   = 'edit_diary.pl';
	my @files = qw(photo1 photo2 photo3);
	# ���
	$form{'submit'} = 'main';
	my $response = eval '$self->post_edit_diary(%form)';
	return 0 if ($@ or not $response);
	return $response->is_success;
}

sub get_delete_diary_confirm {
	my $self  = shift;
	my %form  = @_;
	my $url   = 'delete_diary.pl';
	# ���
	$form{'submit'} = 'confirm';
	my $response = eval '$self->post_delete_diary(%form)';
	return 0 if ($@ or not $response);
	return $response->is_success;
}

sub absolute_url {
	my $self = shift;
	my $url  = shift;
	return undef unless ($url);
	my $base = (@_) ? shift : $self->{'mixi'}->{'base'};
	$url     .= '.pl' if ($url and $url !~ /[\/\.]/);
	return URI->new($url)->abs($base)->as_string;
}

sub absolute_linked_url {
	my $self = shift;
	my $url  = shift;
	return $url unless ($url and $self->response());
	my $res  = $self->response();
	my $base = $res->request->uri->as_string;
	return $self->absolute_url($url, $base);
}

sub save_cookies {
	my $self = shift;
	my $file = shift;
	my $info = '';
	my $result = 0;
	if (not $self->cookie_jar) {
		$info = "[error] Cookie��̵���Ǥ���\n";
	} elsif (not $file) {
		$info = "[error] Cookie����¸����ե�����̾�����ꤵ��ޤ���Ǥ�����\n";
	} else {
		$info = "[info] Cookie��\"${file}\"����¸���ޤ���\n";
		$result = eval "\$self->cookie_jar->save(\$file)";
		$info .= "[error] $@\n" if ($@);
	}
	return $result;
}

sub load_cookies {
	my $self = shift;
	my $file = shift;
	my $info = '';
	my $result = 0;
	if (not $file){ 
		$info = "[error] Cookie���ɤ߹���ե�����̾�����ꤵ��ޤ���Ǥ�����\n";
	} elsif (not $file) {
		$info = "[error] Cookie�ե�����\"${file}\"��¸�ߤ��ޤ���\n";
	} else {
		$info = "[info] Cookie��\"${file}\"�����ɤ߹��ߤޤ���\n";
		$result = eval "\$self->cookie_jar->load(\$file)";
		$info .= "[error] $@\n" if ($@);
	}
	return $result;
}

sub log {
	my $self = shift;
	return &{$self->{'mixi'}->{'log'}}($self, @_);
}

sub dumper_log {
	my $self = shift;
	my $result = undef;
	if (@_) {
		my $dumper = <<EOF;
use Data::Dumper;
\$Data::Dumper::Indent = 1;
my \$log = Data::Dumper::Dumper(\@_);
\$log =~ s/\\n/\\n  /g;
\$log =~ s/\\s+\$/\\n/;
return \$self->log("  \$log");
EOF
		eval "$dumper;";
		return $self->log('[error] ' . $@  . "\n") if ($@);
	}
}

sub abort {
	my $self = shift;
	return &{$self->{'mixi'}->{'abort'}}($self, @_);
}

sub callback_log {
	eval "use Jcode";
	my $use_jcode = ($@) ? 0 : 1;
	my $self  = shift;
	my @logs  = @_;
	my $error = 0;
	foreach my $log (@logs) {
		eval '$log = jcode($log, "euc")->sjis' if ($use_jcode);
		if    ($log !~ /^(\s|\[.*?\])/) { print $log; }
		elsif ($log =~ /^\[error\]/)    { print $log; $error = 1; }
		elsif ($log =~ /^\[usage\]/)    { print $log; }
#		elsif ($log =~ /^\[info\]/)     { print $log; }               # useful for debugging
#		elsif ($log =~ /^\s/)           { print $log; }               # useful for debugging
#		else                            { print $log; }               # useful for debugging
	}
	$self->abort if ($error);
	return $self;
}

sub callback_abort {
	die;
}

sub rewrite {
	my $self = shift;
	return &{$self->{'mixi'}->{'rewrite'}}($self, @_);
}

sub callback_rewrite {
	my $self = shift;
	my $str  = shift;
	$str = $self->remove_tag($str);
	$str = $self->unescape($str);
	return $str;
}

sub escape {
	my $self = shift;
	my $str  = shift;
	my %escaped = ('&' => '&amp;', '"' => '&quot;', '>' => '&gt;', '<' => '&lt;');
	my $re_target = join('|', keys(%escaped));
	$str =~ s/($re_target)/$escaped{$1}/g;
	return $str;
}

sub unescape {
	my $self = shift;
	my $str  = shift;
	my %unescaped = ('amp' => '&', 'quot' => '"', 'gt' => '>', 'lt' => '<', 'nbsp' => ' ', 'apos' => "'", 'copy' => '(c)');
	my $re_target = join('|', keys(%unescaped));
	$str =~ s[&(.*?);]{
		local $_ = lc($1);
		/^($re_target)$/  ? $unescaped{$1} :
		/^#x([0-9a-f]+)$/ ? chr(hex($1)) :
		$_
	}gex;
	return $str;
}

sub remove_tag {
	my $self = shift;
	my $str  = shift;
	my $re_standard_tag = q{[^"'<>]*(?:"[^"]*"[^"'<>]*|'[^']*'[^"'<>]*)*(?:>|(?=<)|$(?!\n))}; #'}}}}
	my $re_comment_tag  = '<!(?:--[^-]*-(?:[^-]+-)*?-(?:[^>-]*(?:-[^>-]+)*?)??)*(?:>|$(?!\n)|--.*$)';
	my $re_html_tag     = qq{$re_comment_tag|<$re_standard_tag};
	$str =~ s/$re_html_tag//g;
	return $str;
}

sub redirect_ok {
	return 1;
}

sub parse_standard_history {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '(\d{4})ǯ(\d{2})��(\d{2})�� (\d{1,2}):(\d{2})';
	my $re_name = '\((.*?)\)';
	my $re_link = '<a href="?(.+?)"?>(.+?)<\/a>';
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>(.+?)<\/table>/s) {
		$content = $1 ;
		while ($content =~ s/<tr bgcolor=#FFFFFF>.*?${re_date}.*?${re_link}\s*${re_name}.*?<\/tr>//is) {
			my $time = sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $4, $5);
			my $subj = $self->rewrite($7);
			my $name = $self->rewrite($8);
			my $link = $self->absolute_url($6, $base);
			push(@items, {'time' => $time, 'subject' => $subj, 'name' => $name, 'link' => $link});
		}
	}
	return @items;
}


sub parse_standard_history2 {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	my $base    = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '(\d{2})��(\d{2})�� (\d{1,2}):(\d{2})';
	my $re_name = '\((.*?)\)';
	my $re_link = '<a href="?(.+?)"?>(.+?)\s*<\/a>';
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>(.+?)<\/table>/s) {
		$content = $1;
		my @today = reverse((localtime)[3..5]);
		$today[0] += 1900;
		$today[1] += 1;
		while ($content =~ s/<tr bgcolor=#FFFFFF>.*?${re_date}.*?${re_link}\s*${re_name}.*?<\/tr>//is) {
			my @date = ($1, $2, $3, $4);
			my $year = ($date[0] == 12 and $today[1] == 1) ? $today[0] - 1 : $today[0];
			my $time = sprintf('%04d/%02d/%02d %02d:%02d', $year, @date);
			my $subj = $self->rewrite($6);
			my $name = $self->rewrite($7);
			my $link = $self->absolute_url($5, $base);
			push(@items, {'time' => $time, 'subject' => $subj, 'name' => $name, 'link' => $link});
		}
	}
	return @items;
}

sub set_response {
	my $self    = shift;
	my $url     = shift;
	my $refresh = (@_ and $_[0] eq 'refresh') ? 1 : 0;
	my $latest  = ($self->response) ? $self->response->request->uri->as_string : undef;
	$url        = $self->absolute_url($url);
	return 0 unless ($url);
	return 1 if ($url eq $latest and not $refresh and $self->response->is_success);
	$self->get($url);
	return 0 unless ($self->response);
	return 0 unless ($self->response->is_success);
	return 1;
}

sub post_add_diary {
	my $self     = shift;
	my %values   = @_;
	my $url      = 'add_diary.pl';
	my @fields   = qw(submit diary_title diary_body photo1 photo2 photo3 orig_size packed);
	my @required = qw(submit diary_title diary_body);
	my @files    = qw(photo1 photo2 photo3);
	my %label    = ('diary_title' => '�����Υ����ȥ�', 'diary_body' => '��������ʸ', 'photo1' => '�̿�1', 'photo2' => '�̿�2', 'photo3' => '�̿�3', orig_size => '���̻���', packed => '�����ǡ���');
	my @errors;
	# �ǡ����������ȥ����å�
	my %form     = map { $_ => $values{$_} } @fields;
	push @errors, map { "$label{$_}����ꤷ�Ƥ���������" } grep { not $form{$_} } @required;
	if ($form{'submit'} eq 'main') {
		# �ץ�ӥ塼�Ѥ��ɲý���
		foreach my $file (@files) {
			next unless ($form{$file});
			if (not -f $form{$file}) {
				push @errors, "[info] $label{$file}�Υե�����\"$form{$file}\"������ޤ���\n" ;
			} else {
				$form{$file} = [$form{$file}];
			}
		}
	}
	if (@errors) {
		$self->log(join('', @errors));
		return undef;
	}
	my $response = eval '$self->post($url, %form)';
	return $response;
}

sub post_edit_diary {
	my $self     = shift;
	my %values   = @_;
	my $url      = 'edit_diary.pl';
	my @fields   = qw(submit diary_id diary_title diary_body photo1 photo2 photo3);
	my @required = qw(submit diary_id diary_title diary_body);
	my @files    = qw(photo1 photo2 photo3);
	my %label    = ('diary_id' => '����ID', 'diary_title' => '�����Υ����ȥ�', 'diary_body' => '��������ʸ', 'photo1' => '�̿�1', 'photo2' => '�̿�2', 'photo3' => '�̿�3');
	my @errors;
	# �ǡ����������ȥ����å�
	my %form     = map { $_ => $values{$_} } @fields;
    my $diary_id = '';
	push @errors, map { "$label{$_}����ꤷ�Ƥ���������" } grep { not $form{$_} } @required;
    $diary_id = $form{'diary_id'};
    delete $form{'diary_id'};
	if ($form{'submit'} eq 'main') {
		# �ե������ɲý���
		foreach my $file (@files) {
			next unless ($form{$file});
			if (not -f $form{$file}) {
				push @errors, "[info] $label{$file}�Υե�����\"$form{$file}\"������ޤ���\n" ;
			} else {
				$form{$file} = [$form{$file}];
			}
		}
	}
	if (@errors) {
		$self->log(join('', @errors));
		return undef;
	}
	my $response = eval '$self->post("$url?id=$diary_id", %form)';
	return $response;
}

sub post_delete_diary {
	my $self     = shift;
	my %values   = @_;
	my $url      = 'delete_diary.pl';
	my @fields   = qw(submit diary_id);
	my @required = qw(submit diary_id);
	my %label    = ('diary_id' => '����ID');
	my @errors;
	# �ǡ����������ȥ����å�
	my %form     = map { $_ => $values{$_} } @fields;
    my $diary_id = '';
	push @errors, map { "$label{$_}����ꤷ�Ƥ���������" } grep { not $form{$_} } @required;
    $diary_id = $form{'diary_id'};
    delete $form{'diary_id'};
	if ($form{'submit'} eq 'main') {
		# �ä˲��⤷�ʤ��ʳ�ǧ���̡�
	}
	if (@errors) {
		$self->log(join('', @errors));
		return undef;
	}
	my $response = eval '$self->post("$url?id=$diary_id", %form)';
	return $response;
}

sub convert_login_time {
	my $self = shift;
	my $time = @_ ? shift : 0;
	if ($time =~ /^\d+$/) { 1; }
	elsif ($time =~ /^(\d+)ʬ/)   { $time = $time * 60; }
	elsif ($time =~ /^(\d+)����/) { $time = $time * 60 * 60; }
	elsif ($time =~ /^(\d+)��/)   { $time = $time * 60 * 60 * 24; }
	else { $self->log("[error] ���������\"$time\"����ϤǤ��ޤ���Ǥ�����\n"); }
	$time = time() - $time;
	my @date = localtime($time);
	$time = sprintf('%04d/%02d/%02d %02d:%02d', $date[5] + 1900, $date[4] + 1, $date[3], $date[2], $date[1]);
	return $time;
}

sub test {
	$| = 1;
	my $mail = (@_) ? shift : $ENV{'MIXI_MAIL'};
	my $pass = (@_) ? shift : $ENV{'MIXI_PASS'};
	my $log  = (@_) ? shift : "WWW-Mixi-${VERSION}-test.log";
	open(OUT, ">$log");
	my $logger = &test_logger;
	my $error = undef;
	my @items = ();
	unless ($mail and  $pass) {
		&{$logger}("mixi�˥�����Ǥ���᡼�륢�ɥ쥹�ȥѥ���ɤ���ꤷ�Ƥ���������\n");
		&{$logger}("[usage] perl -MWWW::Mixi -e \"WWW::Mixi::test('mail\@address', 'password');\"\n");
		exit 1;
	}
	my ($result, $response) = ();
	# ���֥������Ȥ�����
	my $mixi = &test_new($mail, $pass, $logger);            # ���֥������Ȥ�����
	$mixi->test_login;                                      # ������
	$mixi->test_get;                                        # GET�ʥȥåץڡ�����
	$mixi->test_get_main_menu;                              # �ᥤ���˥塼�β���
	$mixi->test_get_banner;                                 # �Хʡ��β���
	$mixi->test_get_tool_bar;                               # �ġ���С��β���
	$mixi->test_get_mainly_categories;                      # ���ץǡ����μ����Ȳ���
	$mixi->test_get_mainly_categories_pagelinks;            # ���ץǡ����μ��Υڡ��������Υڡ���
	$mixi->test_get_details;                                # �ܺ�ɽ����view_���ʤɡˤμ����Ȳ���
	$mixi->test_get_add_diary_preview;                      # �����Υץ�ӥ塼
	$mixi->test_save_and_read_cookies;                      # Cookie���ɤ߽�
	# ��λ
	$mixi->log("��λ���ޤ�����\n");
	exit 0;
}

sub test_logger {
	return sub {
		eval "use Jcode";
		my $use_jcode = ($@) ? 0 : 1;
		my $self  = shift if (ref($_[0]));
		my @logs  = @_;
		my $error = 0;
		foreach my $log (@logs) {
			eval '$log = jcode($log, "euc")->sjis' if ($use_jcode);
			if    ($log !~ /^(\s|\[.*?\])/) { print OUT $log; print $log; }
			elsif ($log =~ /^\[error\]/)    { print OUT $log; print $log; $error = 1; }
			elsif ($log =~ /^\[usage\]/)    { print OUT $log; print $log; }
			elsif ($log =~ /^\[info\]/)     { print OUT $log; print $log; }               # useful for debugging
			elsif ($log =~ /^\s/)           { print OUT $log; }                           # useful for debugging
			else                            { print OUT $log; }                           # useful for debugging
		}
		return $self;
	};
}

sub test_new {
	my ($mail, $pass, $logger) = @_;
	my $error = '';
	&{$logger}("���֥������Ȥ��������ޤ���\n");
	my $mixi = eval "WWW::Mixi->new('$mail', '$pass', '-log' => \$logger)";
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $mixi) {
		$error = "[error] �����ʥ��顼�Ǥ���\n";
	} elsif (not $mixi->{'mixi'}) {
		$error = "[error] mixi��Ϣ���������Ǥ��ޤ���Ǥ�����\n";
	}
	if ($error) {
		&{$logger}({}, "���֥������Ȥ������Ǥ��ޤ���Ǥ�����\n", $error);
		exit 8;
	}
	$mixi->delay(0);
	$mixi->env_proxy;
	return $mixi;
}

sub test_login {
	my $mixi = shift;
	my $error = '';
	$mixi->log("mixi�˥����󤷤ޤ���\n");
	my ($result, $response) = eval '$mixi->login';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $result) {
		if (not $response->is_success) {
			$error = sprintf("[error] %d %s\n", $response->code, $response->message);
			$error .= "[info] Web���������˥ץ�����ɬ�פʻ��ϡ��Ķ��ѿ�HTTP_PROXY�򥻥åȤ��Ƥ���ƻ�Ԥ��Ƥ���������\n" unless($ENV{'HTTP_PROXY'});
		} elsif ($mixi->is_login_required($response)) {
			$error = "[error] " . $mixi->is_login_required($response) . "\n";
		} elsif (not $mixi->session) {
			$error = "[error] ���å����ID������Ǥ��ޤ���Ǥ�����\n";
		} elsif (not $mixi->session) {
			$error = "[error] ��ե�å���URL������Ǥ��ޤ���Ǥ�����\n";
		}
	}
	if ($error) {
		$mixi->log("������Ǥ��ޤ���Ǥ�����\n", $error);
		$mixi->dumper_log($response);
		exit 8;
	} else {
		$mixi->log('[info] ���å����ID��"' . $mixi->session . "\"�Ǥ���\n");
	}
}

sub test_get {
	my $mixi = shift;
	my $error = '';
	$mixi->log("�ȥåץڡ�����������ޤ���\n");
	my $response = eval '$mixi->get("home")';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $response->is_success) {
		$error = sprintf("[error] %d %s\n", $response->code, $response->message);
		$error .= "[info] Web���������˥ץ�����ɬ�פʻ��ϡ��Ķ��ѿ�HTTP_PROXY�򥻥åȤ��Ƥ���ƻ�Ԥ��Ƥ���������\n" unless($ENV{'HTTP_PROXY'});
	} elsif ($mixi->is_login_required($response)) {
		$error = "[error] " . $mixi->is_login_required($response) . "\n";
	}
	if ($error) {
		$mixi->log("�ȥåץڡ����μ����˼��Ԥ��ޤ�����\n", $error);
		$mixi->dumper_log($response);
		exit 8;
	}
}

sub test_get_main_menu {
	my $mixi = shift;
	my $error = '';
	$mixi->log("�ᥤ���˥塼�β��Ϥ򤷤ޤ���\n");
	my @items = eval '$mixi->get_main_menu()';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not @items) {
		$error = "[error] ��˥塼���ܤ����Ĥ���ޤ���Ǥ�����\n";
	}
	if ($error) {
		$mixi->log("�ᥤ���˥塼�β��Ϥ˼��Ԥ��ޤ�����\n", $error);
		$mixi->dumper_log($mixi->response);
		exit 8;
	} else {
		$mixi->dumper_log([@items]);
	}
}

sub test_get_banner {
	my $mixi = shift;
	my $error = '';
	$mixi->log("�Хʡ��β��Ϥ򤷤ޤ���\n");
	my @items = eval '$mixi->get_banner()';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not @items) {
		$error = "[error] �Хʡ������Ĥ���ޤ���Ǥ�����\n";
	}
	if ($error) {
		$mixi->log("�Хʡ��β��Ϥ˼��Ԥ��ޤ�����\n", $error);
		$mixi->dumper_log($mixi->response);
		exit 8;
	} else {
		$mixi->dumper_log([@items]);
	}
}

sub test_get_tool_bar {
	my $mixi = shift;
	my $error = '';
	$mixi->log("�ġ���С��β��Ϥ򤷤ޤ���\n");
	my @items = eval '$mixi->get_tool_bar()';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not @items) {
		$error = "[error] �ġ���С����ܤ����Ĥ���ޤ���Ǥ�����\n";
	}
	if ($error) {
		$mixi->log("�ġ���С��β��Ϥ˼��Ԥ��ޤ�����\n", $error);
		$mixi->dumper_log($mixi->response);
		exit 8;
	} else {
		$mixi->dumper_log([@items]);
	}
}

sub test_get_mainly_categories {
	my $mixi = shift;
	my %categories = (
		'calendar'         => '��������',
		'calendar_term'    => '���������δ���',
		'information'      => '�����Ԥ���Τ��Τ餻',
		'list_bookmark'    => '����������',
		'list_comment'     => '�Ƕ�Υ�����',
		'list_community'   => '���ߥ�˥ƥ�����',
		'list_diary'       => '����',
		'list_diary_capacity' => '��������',
		'list_friend'      => 'ͧ�͡��οͰ���',
		'list_message'     => '������å�����',
		'new_album'        => '�ޥ��ߥ������ǿ�����Х�',
		'new_bbs'          => '���ߥ�˥ƥ��ǿ��񤭹���',
		'new_comment'      => '���������ȵ�������',
		'new_friend_diary' => '�ޥ��ߥ������ǿ�����',
		'new_review'       => '�ޥ��ߥ������ǿ���ӥ塼',
		'self_id'          => '��ʬ��ID',
		'show_log'         => '��������',
		'show_log_count'   => '�������ȿ�',
	);
	foreach my $category (sort(keys(%categories))) {
		my $error = '';
		$mixi->log($categories{$category} . "�μ����Ȳ��Ϥ򤷤ޤ���\n");
		my @items = eval "\$mixi->get_${category}";
		if ($@) {
			$error = "[error] $@\n";
		}
		if ($error) {
			$mixi->log("${category}�μ����Ȳ��Ϥ˼��Ԥ��ޤ�����\n", $error);
			$mixi->dumper_log($mixi->response);
			exit 8;
		} else {
			if (@items) {
				$mixi->dumper_log([@items]);
				$mixi->{'__test_record'}->{$category} = $items[0];
			} else {
				$mixi->log("[info] �쥳���ɤ����Ĥ���ޤ���Ǥ�����\n");
				$mixi->dumper_log($mixi->response);
			}
		}
	}
}

sub test_get_mainly_categories_pagelinks {
	my $mixi = shift;
	my %categories = (
		'calendar'         => '��������',
		'list_community'   => '���ߥ�˥ƥ�����',
		'list_diary'       => '����',
		'list_friend'      => 'ͧ�͡��οͰ���',
		'new_friend_diary' => '�ޥ��ߥ������ǿ�����',
	);
	foreach my $category (sort(keys(%categories))) {
		my $error = '';
		$mixi->log($categories{$category} . "�μ��Υڡ����ؤΥ�󥯤β��Ϥ򤷤ޤ���\n");
		my $next = eval "\$mixi->get_${category}_next()";
		if ($@) {
			$error = "[error] $@\n";
		} elsif (not $next) {
			$mixi->log("[info] ���Υڡ��������Ĥ���ޤ���Ǥ�����\n");
			$mixi->dumper_log($mixi->response);
		} else {
			$mixi->dumper_log($next);
		}
		if ($error) {
			$mixi->log($error);
			$mixi->dumper_log($mixi->response);
			exit 8;
		}
		$mixi->log($categories{$category} . "�����Υڡ����ؤΥ�󥯤β��Ϥ򤷤ޤ���\n");
		if (not $next) {
			$mixi->log("[info] ���Υڡ������ʤ��ä����ᡢ�����åפ���ޤ�����\n");
			next;
		}
		my $previous = eval "\$mixi->get_${category}_previous(\$next->{'link'})";
		if ($@) {
			$error = "[error] $@\n";
		} elsif (not $previous) {
			$mixi->log("[info] ���Υڡ��������Ĥ���ޤ���Ǥ�����\n");
			$mixi->dumper_log($mixi->response);
		} else {
			$mixi->dumper_log($previous);
		}
		if ($error) {
			$mixi->log($error);
			$mixi->dumper_log($mixi->response);
			exit 8;
		}
	}
}

sub test_get_details {
	my $mixi = shift;
	my %methods = (
		'get_view_message'      => ['list_message', '��å�����'],
		'get_view_message_form' => ['list_message', '��å������ֿ�������ե�����'],
	);
	foreach my $method (sort(keys(%methods))) {
		my ($category, $label) = @{$methods{$method}};
		my $item = $mixi->{'__test_record'}->{$category};
		unless ($item) {
			$mixi->log("[info] ${label}���оݥ쥳���ɤ��ʤ����᥹���åפ���ޤ�����\n");
			next;
		}
		my $error = '';
		my $link  = $item->{'link'};
		$mixi->log("$label�μ����Ȳ��Ϥ򤷤ޤ���\n");
		my @items = eval "\$mixi->$method(\$link)";
		if ($@) {
			$error = "[error] $@\n";
		}
		if ($error) {
			$mixi->log("$label�μ����Ȳ��Ϥ˼��Ԥ��ޤ�����\n", $error);
			$mixi->dumper_log($mixi->response);
			exit 8;
		} else {
			if (@items) {
				$mixi->dumper_log([@items]);
			} else {
				$mixi->log("[info] �쥳���ɤ����Ĥ���ޤ���Ǥ�����\n");
				$mixi->dumper_log($mixi->response);
			}
		}
	}
}

sub test_get_add_diary_preview {
	my $mixi = shift;
	my $error = '';
	my %diary = (
		'diary_title' => '���������ȥ�',
		'diary_body' => '������ʸ',
#		'photo1' => '�̿�1�ѥ�'
	);
	$mixi->log("��������Ƥȳ�ǧ���̤β��Ϥ򤷤ޤ���\n");
	my @items = eval '$mixi->get_add_diary_preview(%diary)';
	if ($@) {
		$error = "[error] $@\n";
	}
	if ($@) {
		$mixi->log("��������Ƥȳ�ǧ���̤β��Ϥ˼��Ԥ��ޤ�����\n", $@);
		exit 8;
	} else {
		if (@items) {
			$mixi->dumper_log([@items]);
		} else {
			$mixi->log("[info] ��ǧ���̤Υե����ब���Ĥ���ޤ���Ǥ�����\n");
			$mixi->dumper_log($mixi->response);
		}
	}
}

sub test_save_and_read_cookies {
	my $mixi = shift;
	my $error = '';
	# Cookie����¸
	$mixi->log("Cookie����¸���ޤ���\n");
	my $saved_str   = $mixi->cookie_jar->as_string;
	my $loaded_str  = '';
	my $cookie_file = sprintf('cookie_%s_%s.txt', $$, time);
	$_ = eval '$mixi->save_cookies($cookie_file)';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $_) {
		$error = "[error] cookie����¸�����Ԥ��ޤ�����\n";
	}
	if ($error) {
		$mixi->log("Cookie����¸�Ǥ��ޤ���Ǥ�����\n", $error);
		exit 8;
	}
	# Cookie���ɹ�
	$mixi->log("Cookie���ɹ��򤷤ޤ���\n");
	$mixi->cookie_jar->clear;
	$_ = eval '$mixi->load_cookies($cookie_file)';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $_) {
		$error = "[error] cookie���ɹ������Ԥ��ޤ�����\n";
	} else {
		$loaded_str = $mixi->cookie_jar->as_string;
		$error = "[error] ��¸����Cookie���ɤ߹����Cookie�����פ��ޤ���\n" if ($saved_str ne $loaded_str);
	}
	if ($error) {
		$mixi->log("Cookie���ɹ���ޤ���Ǥ�����\n", $error);
		exit 8;
	}
	unlink($cookie_file);
}

1;

=head1 NAME

WWW::Mixi - Perl extension for scraping the MIXI social networking service.

=head1 SYNOPSIS

  require WWW::Mixi;
  $mixi = WWW::Mixi->new('me@foo.com', 'password');
  $mixi->login;
  my $res = $mixi->get('home.pl');
  print $res->content;

=head1 DESCRIPTION

WWW::Mixi uses LWP::RobotUA to scrape mixi.jp.
This provide login method, get and put method, and some parsing method for user who create mixi spider.

I think using WWW::Mixi is better than using LWP::UserAgent or LWP::Simple for accessing Mixi.
WWW::Mixi automatically enables cookie, take delay 1 second for each access, take care robot exclusions.

See "mixi.pod" for more detail.

=head1 SEE ALSO

L<LWP::UserAgent>, L<WWW::RobotUA>, L<HTTP::Request::Common>

=head1 CREDITS

WWW::Mixi is developed by Makio Tsukamoto <tsukamoto@gmail.com>.

Thanks to DonaDona (http://hsj.jp/) for methods to post or delete a diary entry, to parse diary list.
Topia (http://clovery.jp/) for some bugfixes.
shino (http://www.freedomcat.com/) for method to parse diary entry and some bugfixes.

=head1 COPYRIGHT

Copyright 2004-2005 Makio Tsukamoto.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

