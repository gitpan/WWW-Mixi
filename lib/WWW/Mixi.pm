package WWW::Mixi;

use strict;
use Carp ();
use vars qw($VERSION @ISA);

$VERSION = sprintf("%d.%02d", q$Revision: 0.36$ =~ /(\d+)\.(\d+)/);

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

	# オプションの処理
	Carp::croak('WWW::Mixi mail address required') unless $email;
	# Carp::croak('WWW::Mixi password required') unless $password;

	# オブジェクトの生成
	my $name = "WWW::Mixi/" . $VERSION;
	my $rules = WWW::Mixi::RobotRules->new($name);
	my $self = LWP::RobotUA->new($name, $email, $rules);
	$self = bless $self, $class;
	$self->from($email);
	$self->delay(1/60);

	# 独自変数の設定
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
	my $next = ($self->{'mixi'}->{'next_url'}) ? $self->{'mixi'}->{'next_url'} : '/home.pl';
	my $password = (@_) ? shift : $self->{'mixi'}->{'password'};
	return undef unless (defined($password) and length($password));
	my %form = (
		'email'    => $self->{'mixi'}->{'email'},
		'password' => $password,
		'next_url' => $self->absolute_url($next),
	);
	$self->enable_cookies;
	# ログイン
	$self->log("[info] 再ログインします。\n") if ($self->session);
	my $res = $self->post($page, %form);
	$self->{'mixi'}->{'refresh'} = ($res->is_success and $res->headers->header('refresh') =~ /url=([^ ;]+)/) ? $self->absolute_url($1) : undef;
	$self->{'mixi'}->{'password'} = $password if ($res->is_success);
	return $res;
}

sub is_logined {
	my $self = shift;
	return ($self->session and $self->stamp) ? 1 : 0;
}

sub is_login_required {
	my $self = shift;
	my $res  = (@_) ? shift : $self->{'mixi'}->{'response'};
	if    (not $res)             { return "ページを取得できていません。"; }
	elsif (not $res->is_success) { return sprintf('ページ取得に失敗しました。（%s）', $res->message); }
	else {
		my $re_attr = '(?:"[^"]+"|\'[^\']+\'|[^\s<>]+)\s+';
		my $content = $res->content;
		return 0 if ($content !~ /<form (?:$re_attr)*action=("[^""]+"|'[^'']+'|[^\s<>]+)/);
		return 0 if ($self->absolute_url($1) ne $self->absolute_url('login.pl'));
		$self->{'mixi'}->{'next_url'} = ($content =~ /<input type=hidden name=next_url value="(.*?)">/) ? $1 : '/home.pl';
		return "Login Failed ($1)" if ($content =~ /<b><font color=#DD0000>(.*?)<\/font><\/b>/);
		return 'Login Required';
	}
	return 0;
}

sub session {
	my $self = shift;
	if (@_) {
		my $session = shift;
		$self->enable_cookies;
		$self->cookie_jar->set_cookie(undef, 'BF_SESSION', $session, '/', 'mixi.jp', undef, 1, undef, undef, 1);
	}
	return undef unless ($self->cookie_jar);
	return ($self->cookie_jar->as_string =~ /\bSet-Cookie.*?:.*? BF_SESSION=(.*?);/) ? $1 : undef;
}

sub stamp {
	my $self = shift;
	if (@_) {
		my $stamp = shift;
		$self->enable_cookies;
		$self->cookie_jar->set_cookie(undef, 'BF_STAMP', $stamp, '/', 'mixi.jp', undef, 1, undef, undef, 1);
	}
	return undef unless ($self->cookie_jar);
	return ($self->cookie_jar->as_string =~ /\bSet-Cookie.*?:.*? BF_STAMP=(.*?);/) ? $1 : undef;
}

sub refresh { return $_[0]->{'mixi'}->{'refresh'}; }

sub request {
	my $self = shift;
	my @args = @_;
	my $res = $self->SUPER::request(@args);
	
	if ($res->is_success) {
		# check contents existence
		if ($res->content and $res->content =~ /^\Qデータはありません。\E<html>/) {
			$res->code(400);
			$res->message('No Data');
		# check rejcted by too frequent requests.
		} elsif ($res->content and $res->content =~ /^\Q間隔を空けない連続的なページの遷移・更新を頻繁におこなわれている\E/) {
			$res->code(503);
			$res->message('Too frequently requests');
		# check rejcted since content is closed.
		} elsif ($res->content and $res->content =~ /^\Qアクセスできません\E<html>/) {
			$res->code(403);
			$res->message('Closed content');
		# check login form existence
		} elsif (my $message = $self->is_login_required($res)) {
			$res->code(401);
			$res->message($message);
		}
	}
	
	# store and return response
	$self->{'mixi'}->{'response'} = $res;
	return $res;
}

sub get {
	my $self = shift;
	my $url  = shift;
	$url     = $self->absolute_url($url);
	$self->log("[info] GETメソッドで\"${url}\"を取得します。\n");
	# 取得
	my $res  = $self->request(HTTP::Request->new('GET', $url));
	$self->log("[info] リクエストが処理されました。\n");
	return $res;
}

sub post {
	my $self = shift;
	my $url  = shift;
	$url     = $self->absolute_url($url);
	$self->log("[info] POSTメソッドで\"${url}\"を取得します。\n");
	# リクエストの生成
	my @form = @_;
	my $req  = (grep {ref($_) eq 'ARRAY'} @form) ?
	           &HTTP::Request::Common::POST($url, Content_Type => 'form-data', Content => [@form]) : 
	           &HTTP::Request::Common::POST($url, [@form]);
	$self->log("[info] リクエストが生成されました。\n");
	# 取得
	my $res = $self->request($req);
	$self->log("[info] リクエストが処理されました。\n");
	return $res;
}

sub response {
	my $self = shift;
	return $self->{'mixi'}->{'response'};
}

sub parse_main_menu {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
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
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
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
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
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
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<!-- start: お知らせ -->.*?<table BORDER=0 CELLSPACING=0 CELLPADDING=0>(.*?)<\/table>/is) {
		$content = $1;
		$content =~ s/[\r\n]+//gs;
		$content =~ s/<!--.*?-->//g;
		while ($content =~ s/<tr><td>(.*?)<\/td><td>(.*?)<\/td><td>(.*?)<\/td><\/tr>//i) {
			my ($subject, $linker) = ($1, $3);
			my $re_attr_val = '(?:"[^"]+"|\'[^\']+\'|[^\s<>]+)\s*';
			my $style = {};
			print "\n\n$subject\n$linker\n";
			$subject =~ s/^.*?・<\/font>(?:&nbsp;| )//;
			while ($subject =~ s/^\s*<([^<>]*)>\s*//) {
				my $tag = lc($1);
				my ($tag_part, $attr_part) = split(/\s+/, $tag, 2);
				print "[tag] $tag_part [attr] $attr_part\n";
				$style->{'font-weight'} = 'bold' if ($tag_part eq 'b');
				while ($attr_part =~ s/([^\s<>=]+)(?:=($re_attr_val))?//) {
					my ($attr, $val) = ($1, $2);
					$val =~ s/^"(.*)"$/$1/ or $val =~ s/^'(.*)'$/$1/;
					$val = $self->unescape($val);
					print "[attr] $attr [val] $val\n";
					if    ($attr eq 'style') { $style->{$1} = $2 while ($val =~ s/([^\s:]+)\s*:\s*([^\s:]+)//); }
					elsif ($attr eq 'color') { $style->{'color'} = $val; }
				}
			}
			$subject =~ s/\s*<.*?>\s*//g;
			my ($link, $description) = ($1, $2) if ($linker =~ /<a href=(.*?) .*?>(.*?)<\/a>/i);
			my $item = {
				'subject'     => $self->rewrite($subject),
				'style'       => $style,
				'link'        => $self->absolute_url($link, $base),
				'description' => $self->rewrite($description)
			};
			push(@items, $item);
		}
	}
	return @items;
}

sub parse_calendar { my $self = shift; return $self->parse_show_calendar(@_); }
sub parse_calendar_term { my $self = shift; return $self->parse_show_calendar_term(@_); }
sub parse_calendar_next { my $self = shift; return $self->parse_show_calendar_next(@_); }
sub parse_calendar_previous { my $self = shift; return $self->parse_show_calendar_previous(@_); }

sub parse_community_id {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my $item;
	if ($content =~ /view_community.pl\?id=(\d+) /) {
		$item = $1;
	}
	return $item;
}

sub parse_list_bbs {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '<td ALIGN=center ROWSPAN=3 NOWRAP bgcolor=#FFD8B0>(\d{2})月(\d{2})日<br>(\d{1,2}):(\d{2})</td>';
	my $re_subj = '<td bgcolor=#FFF4E0>&nbsp;(.+?)</td>';
	my $re_desc = '<td CLASS=h120>\n\n\n(.*?)\n</td>';
	my $re_name = '\((.*?)\)';
	my $re_link = '<a href="?(.+?)"?>書き込み\((\d+)\)<\/a>';
	if ($content =~ /<table BORDER=0 cellspacing=1 cellpadding=3 width=630>(.+)<\/table>/s) {
		$content = $1 ;
		while ($content =~ s/<tr VALIGN=top>.*?${re_date}.*?${re_subj}(.*?)${re_desc}.*?${re_link}.*?<\/tr>//is) {
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

sub parse_list_bbs_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5>.*?<a href=([^<>]*?list_bbs.pl[^<>]*?)>([^<>]*?)<\/a><\/td>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_bbs_previous {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5><a href=([^<>]*?list_bbs.pl[^<>]*?)>([^<>]*?)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_bookmark {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>(.+?)<!--フッタ-->/s) {
		$content = $1;
		while ($content =~ s/<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=550>(.*?)<\/table>//is) {
			my $record = $1;
			my @lines = ($record =~ /<tr.*?>(.*?)<\/tr>/gis);
			my $item = {};
			# parse record
			($item->{'link'}, $item->{'image'})  = ($1, $2) if ($lines[0] =~ /<td WIDTH=90 .*?><a href="([^"]*show_friend.pl\?id=\d+)"><img SRC="([^"]*)".*?>/is);
			($item->{'subject'}, $item->{'gender'}) = ($1, $2) if ($lines[0] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?) \((.*?)\)<\/td>/is);
			$item->{'description'} = $1 if ($lines[1] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
			$item->{'time'}    = $1 if ($lines[2] =~ /<td BGCOLOR=#FFFFFF WIDTH=140>(.*?)<\/td>/is);
			# format
			foreach (qw(image link)) { $item->{$_} = $self->absolute_url($item->{$_}, $base) if ($item->{$_}); }
			foreach (qw(subject description gender)) { $item->{$_} = $self->rewrite($item->{$_}); }
			$item->{'time'} = $self->convert_login_time($item->{'time'}) if ($item->{'time'});
			push(@items, $item) if ($item->{'subject'} and $item->{'link'});
		}
	}
	@items = sort { $b->{'time'} cmp $a->{'time'} } @items;
	return @items;
}

sub parse_list_comment {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_list_community {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $status_backgrounds = {
		'http://img.mixi.jp/img/bg_orange1-.gif' => '管理者',
	};
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>(.+?)<\/table>/s) {
		$content = $1;
		while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is) {
			my ($image_part, $text_part) = ($1, $2);
			my @images = ($image_part =~ /<td WIDTH=20% HEIGHT=100 background=http:\/\/img.mixi.jp\/img\/bg_[a-z0-9-]+.gif>.*?<\/td>/gi);
			my @texts  = ($text_part =~ /<td>(.*?)<\/td>/gi);
			for (my $i = 0; $i < @images or $i < @texts; $i++) {
				my $item = {};
				my ($image, $text) = ($images[$i], $texts[$i]);
				($item->{'subject'}, $item->{'count'}) = ($1, $2) if ($text =~ /^\s*(.*?)\((\d+)\)\s*$/);
				($item->{'background'}, $item->{'link'}, $item->{'image'}) = ($1, $2, $3) if ($image =~ /<td .*? background=([^<> ]*).*?><a href=(.*?)><img SRC=(.*?) border=0><\/a>/);
				if ($item->{'link'}) {
					$item->{'subject'}    = $self->rewrite($item->{'subject'});
					$item->{'link'}       = $self->absolute_url($item->{'link'}, $base);
					$item->{'image'}      = $self->absolute_url($item->{'image'}, $base);
					$item->{'background'} = $self->absolute_url($item->{'background'}, $base);
					$item->{'status'}     = $status_backgrounds->{$item->{'background'}};
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
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=580 BGCOLOR=#F8A448>.*?<a href=([^<>]*?)>([^<>]*?)<\/a><\/td>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_community_previous {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return unless ($content =~ /<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=580 BGCOLOR=#F8A448>.*?<td ALIGN=right BGCOLOR=#EED6B5><a href=["']?(.+?)['"]?>([^<>]+)<\/a>/);
	my $subject  = $2;
	my $link     = $self->absolute_url($1, $base);
	my $previous = {'link' => $link, 'subject' => $2};
	return $previous;
}

sub parse_list_diary {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '<font COLOR=#996600>(\d{2})月(\d{2})日<br>(\d{1,2}):(\d{2})</font>';
	my $re_subj = '<td bgcolor=#F2DDB7>&nbsp;(.+?)</td>';
	my $re_desc = '<td CLASS=h120>\n(.*?)\n(.+?)\n<br>\n\n</td>';
	my $re_name = '\((.*?)\)';
	my $re_link = '<a href="?(.+?)"?>コメント\((\d+)\)<\/a>';
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
	return unless ($res and $res->is_success);
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return unless ($content =~ /<table width="165" border="0" cellspacing="1" cellpadding="2">(.*?)<\/table>/is);
	my $box      = $1;
	return unless ($box =~ /(\d+\.\d+).*?MB\/.*?(\d+\.\d+).*?MB/);
	my $capacity = {'used' => $1, 'max' => $2};
	return $capacity;
}

sub parse_list_diary_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5>.*?<a href=([^<>]*?list_diary.pl[^<>]*?)>([^<>]*?)<\/a><\/td>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_diary_previous {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5><a href=([^<>]*?list_diary.pl[^<>]*?)>([^<>]*?)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_diary_monthly_menu {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<!-- start: monthly menu -->(.+)<!-- end: monthly menu -->/s) {
		$content = $1;
		while ($content =~ s/<a HREF=['"]?(list_diary.pl\?year=(\d+)\&month=(\d+))['"]?.*?>.*?<\/a>//is) {
			push(@items, {'link' => $self->absolute_url($1, $base), 'year' => $2, 'month' => $3});
		}
	}
	return @items;
}

sub parse_list_friend {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $status_backgrounds = {
		'http://img.mixi.jp/img/bg_orange1-.gif' => '1時間以内',
		'http://img.mixi.jp/img/bg_orange2-.gif' => '1日以内',
	};
	my @time1   = reverse((localtime(time - 3600))[0..5]);
	my @time2   = reverse((localtime(time - 3600 * 24))[0..5]);
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>(.+?)<\/table>/s) {
		$content = $1 ;
		while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is) {
			my ($image_part, $text_part) = ($1, $2);
			my @images = ($image_part =~ /<td WIDTH=20% HEIGHT=100 background=http:\/\/img.mixi.jp\/img\/bg_[a-z0-9-]+.gif>.*?<\/td>/gi);
			my @texts  = ($text_part =~ /<td>(.*?)<\/td>/gi);
			for (my $i = 0; $i < @images or $i < @texts; $i++) {
				my $item = {};
				my ($image, $text) = ($images[$i], $texts[$i]);
				($item->{'subject'}, $item->{'count'}) = ($1, $2) if ($text =~ /^\s*(.+?)\((\d+)\)/);
				($item->{'background'}, $item->{'link'}, $item->{'image'}) = ($1, $2, $3) if ($image =~ /<td .*? background=([^<> ]*).*?><a href=(.*?)><img alt=(?:.*?) SRC=(.*?) border=0><\/a>/);
				if ($item->{'link'}) {
					$item->{'subject'}    = $self->rewrite($item->{'subject'});
					$item->{'link'}       = $self->absolute_url($item->{'link'}, $base);
					$item->{'id'}         = $2 if ($item->{'link'} =~ /(.*?)?id=(\d*)/); 
					$item->{'image'}      = $self->absolute_url($item->{'image'}, $base);
					$item->{'background'} = $self->absolute_url($item->{'background'}, $base);
					$item->{'status'}     = $status_backgrounds->{$item->{'background'}};
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
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /&nbsp;&nbsp;<a href=([^<>]*?list_friend.pl\?[^<>\s]*page=[^<>\s]*)>((?:(?!<\/a>).)*)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_friend_previous {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return unless ($content =~ /<a href=([^<>\s]*list_friend.pl\?[^<>\s]*page=[^<>\s]*)>((?:(?!<\/a>).)*)<\/a>&nbsp;&nbsp;/);
	my $subject  = $2;
	my $link     = $self->absolute_url($1, $base);
	my $previous = {'link' => $link, 'subject' => $2};
	return $previous;
}

sub parse_list_member {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>(.+?)<\/table>/s) {
		$content = $1 ;
		while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is) {
			my ($image_part, $text_part) = ($1, $2);
			my @images = ($image_part =~ /<td WIDTH=20% HEIGHT=100 background=http:\/\/img.mixi.jp\/img\/bg_line.gif>.*?<\/td>/gi);
			my @texts  = ($text_part =~ /<td>(.*?)<\/td>/gi);
			for (my $i = 0; $i < @images or $i < @texts; $i++) {
				my $item = {};
				my ($image, $text) = ($images[$i], $texts[$i]);
				($item->{'subject'}, $item->{'count'}) = ($1, $2) if ($text =~ /^\s*(.+?)\((\d+)\)/);
				($item->{'background'}, $item->{'link'}, $item->{'image'}) = ($1, $2, $3) if ($image =~ /<td .*? background=([^<> ]*).*?><a href=(.*?)><img SRC=(.*?) border=0><\/a>/i);
				if ($item->{'link'}) {
					$item->{'subject'}    = $self->rewrite($item->{'subject'});
					$item->{'link'}       = $self->absolute_url($item->{'link'}, $base);
					$item->{'id'}         = $2 if ($item->{'link'} =~ /(.*?)?id=(\d*)/); 
					$item->{'image'}      = $self->absolute_url($item->{'image'}, $base);
					$item->{'background'} = $self->absolute_url($item->{'background'}, $base);
					push(@items, $item);
				}
			}
		}
	}
	return @items;
}

sub parse_list_member_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /&nbsp;&nbsp;<a href=([^<>]*?list_member.pl\?[^<>\s]*page=[^<>\s]*)>((?:(?!<\/a>).)*)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_member_previous {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return unless ($content =~ /<a href=([^<>\s]*list_member.pl\?[^<>\s]*page=[^<>\s]*)>((?:(?!<\/a>).)*)<\/a>&nbsp;&nbsp;/);
	my $subject  = $2;
	my $link     = $self->absolute_url($1, $base);
	my $previous = {'link' => $link, 'subject' => $2};
	return $previous;
}

sub parse_list_message {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
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
	if ($content =~ /<!--受信箱一覧-->.*?<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=553>(.+?)<\/table>/s) {
		$content = $1;
		while ($content =~ s/<tr BGCOLOR="(#FFF7E1|#FFFFFF)">(.*?)<\/tr>//s) {
			my $message  = $2;
			my $emvelope = ($message =~ s/<td[^<>]*>\s*<img SRC="(.*?)".*?>\s*<\/td>//s) ? $self->absolute_url($1, $base) : undef;
			my $status   = $emvelopes{$emvelope} ? $emvelopes{$emvelope} : 'unknown';
			if ($message =~ /<td>([^<>]*?)<\/td>\s*<td>${re_link}<\/td>\s*<td>(\d{2})月(\d{2})日<\/td>/is) {
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

sub parse_list_outbox {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base      = $res->request->uri->as_string;
	my $content   = $res->content;
	my @items     = ();
	my $re_link   = '<a href="?(.+?)"?>(.+?)<\/a>';
	if ($content =~ /<!--送信済み一覧-->.*?<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=553>(.+?)<\/table>/s) {
		$content = $1;
		while ($content =~ s/<tr BGCOLOR="?(#FFF7E1|#FFFFFF)"?>(.*?)<\/tr>//s) {
			my $message  = $2;
			if ($message =~ /<td>([^<>]*?)<\/td>\s*<td>${re_link}<\/td>\s*<td>(\d{2})月(\d{2})日<\/td>/is) {
				my ($name, $link, $subj) = ($1, $2, $3);
				my $time = sprintf('%02d/%02d', $4, $5);
				my $item = {
					'time'     => $time,
					'subject'  => $self->rewrite($subj),
					'name'     => $self->rewrite($name),
					'link'     => $self->absolute_url($link, $base),
				};
				push(@items, $item);
			}
		}
	}
	return @items;
}

sub parse_list_request {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>(.+?)<!--フッタ-->/s) {
		$content = $1;
		while ($content =~ s/<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=550>(.*?)<\/table>//is) {
			my $record = $1;
			my @lines = ($record =~ /<tr.*?>(.*?)<\/tr>/gis);
			my $item = {};
			# parse record
			($item->{'link'}, $item->{'image'})  = ($1, $2) if ($lines[0] =~ /<td WIDTH=90 .*?><a href="([^"]*show_friend.pl\?id=\d+)"><img SRC="([^"]*)".*?>/is);
			($item->{'subject'}, $item->{'gender'}) = ($1, $2) if ($lines[0] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?) \((.*?)\)<\/td>/is);
			$item->{'description'} = $1 if ($lines[1] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
			$item->{'message'} = $1 if ($lines[2] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
			$item->{'time'} = $1 if ($lines[3] =~ /<td BGCOLOR=#FFFFFF WIDTH=140>(.*?)<\/td>/is);
			# format
			foreach (qw(image link)) { $item->{$_} = $self->absolute_url($item->{$_}, $base) if ($item->{$_}); }
			foreach (qw(subject description gender)) { $item->{$_} = $self->rewrite($item->{$_}); }
			$item->{'time'} = $self->convert_login_time($item->{'time'}) if ($item->{'time'});
			push(@items, $item) if ($item->{'subject'} and $item->{'link'});
		}
	}
	@items = sort { $b->{'time'} cmp $a->{'time'} } @items;
	return @items;
}

sub parse_new_album {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_new_bbs {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_new_bbs_next {
	my $self    = shift;
	return $self->parse_standard_history_next(@_);
}

sub parse_new_bbs_previous {
	my $self    = shift;
	return $self->parse_standard_history_previous(@_);
}

sub parse_new_comment {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_new_diary { my $self = shift; return $self->parse_search_diary(@_); }
sub parse_new_diary_next { my $self = shift; return $self->parse_search_diary_next(@_); }
sub parse_new_diary_previous { my $self = shift; return $self->parse_search_diary_previous(@_); }

sub parse_new_friend_diary {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_new_friend_diary_next {
	my $self    = shift;
	return $self->parse_standard_history_next(@_);
}

sub parse_new_friend_diary_previous {
	my $self    = shift;
	return $self->parse_standard_history_previous(@_);
}

sub parse_new_review {
	my $self    = shift;
	return $self->parse_standard_history(@_);
}

sub parse_release_info {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->base->as_string;
	my $content  = $res->content;
	my @items    = ();
	my $re_subj  = '<b><font COLOR=#605048>(.+?)</font></b>';
	my $re_date  = '<td ALIGN=right><font COLOR=#605048>(\d{4}).(\d{2}).(\d{2})</font></td>';
	my $re_desc  = '<td CLASS=h130>(.*?)</td>';
	if ($content =~ /新機能リリース・障害のご報告(.*?)<!--フッタ-->/s) {
		$content = $1;
		while ($content =~ s/<table BORDER=0 CELLSPACING=0 CELLPADDING=2 WIDTH=520 BGCOLOR=#F7F0E6>.*?${re_subj}.*?${re_date}.*?${re_desc}.*?<!--▼1つ分ここまで-->//is) {
			my $subj = $1;
			my $date = sprintf('%04d/%02d/%02d', $2, $3, $4);
			my $desc = $5;
			$subj = $self->rewrite($subj);
			$desc = $self->rewrite($desc);
			$desc =~ s/^$//g;
			push(@items, {'time' => $date, 'description' => $desc, 'subject' => $subj});
		}
	}
	return @items;
}

sub parse_self_id {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my $self_id = ($content =~ /\(URL は http:\/\/mixi.jp\/show_friend.pl\?id=(\d+) です。\)/) ? $1 : 0;
	return $self_id;
}

sub parse_search_diary {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my @time    = localtime();
	my ($month, $year) = ($time[4] + 1, $time[5] + 1900);
	if ($content =~ m{<!--///// 最新日記検索ここまで /////-->(.+?)<!--フッタ-->}s) {
		$content = $1;
		while ($content =~ s/<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=550>(.*?)<\/table>//is) {
			my $record = $1;
			my @lines = ($record =~ /<tr.*?>(.*?)<\/tr>/gis);
			my $item = {};
			# parse record
			($item->{'link'}, $item->{'image'})  = ($1, $2) if ($lines[0] =~ /<td WIDTH=90 .*?><a href="([^"]*view_diary.pl\?id=\d+\&owner_id=\d+)"><img SRC="([^"]*)".*?>/is);
			($item->{'name'}, $item->{'gender'}) = ($1, $2) if ($lines[0] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?) \((.*?)\).*<\/td>/is);
			$item->{'subject'} = $1 if ($lines[1] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
			$item->{'description'} = $1 if ($lines[2] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
			$item->{'time'}    = $1 if ($lines[3] =~ /<td BGCOLOR=#FFFFFF WIDTH=220>(.*?)<\/td>/is);
			# format
			my @time = ($item->{'time'} =~ /\d+/g);
			unshift(@time, ($time[0] == $month) ? $year : $year - 1) if (@time == 4);
			$item->{'time'} = (@time == 5) ? sprintf('%04d/%02d/%02d %02d:%02d', @time) : '';
			foreach (qw(image link)) { $item->{$_} = $self->absolute_url($item->{$_}, $base) if ($item->{$_}); }
			foreach (qw(name subject description gender time)) {
				$item->{$_} =~ s/<.*?>//g if ($item->{$_});
				$item->{$_} = $self->rewrite($item->{$_});
			}
			push(@items, $item) if ($item->{'subject'} and $item->{'link'});
		}
	}
	return @items;
}

sub parse_search_diary_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5>.*?<a href=([^<>]*?search_diary.pl[^<>]*?)>([^<>]*?)<\/a><\/td>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_search_diary_previous {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5><a href=([^<>]*?search_diary.pl[^<>]*?)>([^<>]*?)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_show_calendar {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->base->as_string;
	my $content  = $res->content;
	my %icons    = ('i_sc-.gif' => '予定', 'i_bd.gif' => '誕生日', 'i_iv1.gif' => '参加イベント', 'i_iv2.gif' => 'イベント');
	my %whethers = ('1' => '晴', '2' => '曇', '3' => '雨', '4' => '雪', '8' => 'のち', '9' => 'ときどき');
	my @items    = ();
	my $term     = $self->parse_show_calendar_term($res) or return undef; 
	if ($content =~ /<table width="670" border="0" cellspacing="1" cellpadding="3">(.+?)<\/table>/s) {
		$content = $1;
		$content =~ s/<tr ALIGN=center BGCOLOR=#FFF1C4>.*?<\/tr>//is;
		while ($content =~ s/<td HEIGHT=65 [^<>]*><font COLOR=#996600>(\S*?)<\/font>(.*?)<\/td>//is) {
			my $date = $1;
			my $text = $2;
			next unless ($date =~ /(\d+)/);
			$date = sprintf('%04d/%02d/%02d', $term->{'year'}, $term->{'month'}, $1);
			if ($text =~ s/<img SRC=(.*?) WIDTH=23 HEIGHT=16 ALIGN=absmiddle>(.*?)<\/font><\/font>//) {
				my $item = { 'subject' => "天気", 'link' => undef, 'name' => $2, 'time' => $date, 'icon' => $1};
				$item->{'icon'} = $self->absolute_url($item->{'icon'}, $base);
				my $weather = ($item->{'icon'} =~ /i_w(\d+).gif$/) ? $1 : '不明';
				$weather    =~ s/(\d)/$whethers{$1}/g;
				$item->{'name'} = sprintf("%s(%s%%)", $weather, $self->rewrite($item->{'name'}));
				push(@items, $item);
			}
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
				$item->{'subject'} = ($item->{'subject'} =~ /([^\/]+)$/ and $icons{$1}) ? $icons{$1} : "不明($1)";
				$item->{'link'} = $self->absolute_url($item->{'link'}, $base);
				$item->{'icon'} = $self->absolute_url($item->{'icon'}, $base);
				$item->{'subject'} = $self->rewrite($item->{'subject'});
				$item->{'name'} = $self->rewrite($item->{'name'});
				push(@items, $item);
			}
		}
	}
	return @items;
}

sub parse_show_calendar_term {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<a href="show_calendar.pl\?year=(\d+)&month=(\d+)&pref_id=13">[^&]*?<\/a>/);
	return {'year' => $1, 'month' => $2};
}

sub parse_show_calendar_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<a href="(show_calendar.pl\?.*?)">([^<>]+?)&nbsp;&gt;&gt;/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $subject};
	return $next;
}

sub parse_show_calendar_previous {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<a href="(show_calendar.pl\?.*?)">&lt;&lt;&nbsp;([^<>]+)/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $subject};
	return $next;
}

sub parse_show_friend_outline {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	my $outline  = {'link' => $base};
	return unless ($content =~ /<img [^<>]*?src=["']?http:\/\/img.mixi.jp\/img\/q_yellow2.gif['"]?[^<>]*?>[^\r\n]*\n(.+?)\n[^\r\n]*?<img [^<>]*?src=["']?http:\/\/img.mixi.jp\/img\/q_yellow3.gif['"]?[^<>]*?>/s);
	$content = $1;
	# parse relation
	if ($content =~ s/<td ALIGN=center COLSPAN=3>(.*?)<table BORDER=0 CELLSPACING=0 CELLPADDING=1 BGCOLOR=#D3B16D>//s) {
		my $relation_part = $1;
		my @nodes = ($relation_part =~ /(<a href=show_friend.pl\?id=\d+>.*?<\/a>)/g);
		$outline->{'step'} = @nodes;
		if ($outline->{'step'} == 2) {
			if ($nodes[0] =~ /<a href="?(.+?)"?>(.+?)<\/a>/) {
				my ($link, $name) = ($1, $2);
				$outline->{'relation'} = { 'link' => $self->absolute_url($link, $base), 'name' => $self->rewrite($name) };
			} else {
				$outline->{'relation'} = { 'link' => '', 'name' => '' };
			}
		}
	}
	# parse image
	if ($content =~ s/<table BORDER=0 CELLSPACING=0 CELLPADDING=3 WIDTH=250 BGCOLOR=#FFFFFF>(.*?)<\/table>//s) {
		my $image_part = $1;
		$outline->{'image'} = ($image_part =~ s/<img SRC="(.*?)".*?VSPACE=2.*?>//) ? $self->absolute_url($1, $base) : '';
	}
	# parse nickname
	if ($content =~ s/([^\n]+)さん\((\d+)\)<br>\n<span class="f08x">\((.*?)\)<\/span><br>//) {
		my ($name, $count, $desc) = ($1, $2, $3);
		$outline->{'name'} = $self->rewrite($name);
		$outline->{'count'} = $count;
		$outline->{'description'} = $self->rewrite($desc);
	}
	return $outline;
}

sub parse_show_friend_profile {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my $profile = {};
	my $re_link = '<a href=.*?>(.+?)<\/a>';
	return unless ($content = ($content =~ /<!--プロフィール-->(.+?)<!--プロフィールここまで-->/s) ? $1 : '');
	return unless ($content = ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=425>(.+?)<!-- start:/s) ? $1 : '');
	while ($content =~ s/<tr BGCOLOR=#FFFFFF>(.*?)<\/tr>//is) {
		my $row = $1;
		my ($key, $val) = ($row =~ /<td\b.*?>(.*?)<\/td>/gs);
		$key =~ s/&nbsp;//g;
		$key = $self->rewrite($key);
		$key =~ s/(^\s+|\s+$)//gs;
		$val =~ s/[\r\n]//g;
		$val =~ s/<br ?\/?>/\n/g;
		$val =~ s/$re_link/$1/g;
		$val = $self->rewrite($val);
		$val =~ s/(^\s+|\s+$)//gs;
		$profile->{$key} = $val;
	}
	return $profile if (keys(%{$profile}));
	return;
}

sub parse_show_log {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '(\d{4})年(\d{2})月(\d{2})日 (\d{1,2}):(\d{2})';
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
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my $count   = ($content =~ /ページ全体のアクセス数：<b>(\d+)<\/b> アクセス/) ? $1 : 0;
	return $count;
}

sub parse_view_bbs {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '<td rowspan="3" width="110" bgcolor="#ffd8b0" align="center" valign="top" nowrap>(\d{4})年(\d{2})月(\d{2})日<br>(\d{1,2}):(\d{2})</td>';
	my $re_subj = '<td bgcolor="#fff4e0">&nbsp;(.+?)</td>';
	my $re_desc = '</table>(.+?)</td>';
	my $re_c_date = '<td rowspan="2" width="110" bgcolor="#f2ddb7" align="center" nowrap>\n(\d{4})年(\d{2})月(\d{2})日<br>\n(\d{1,2}):(\d{2})';
	my $re_c_desc = '<td class="h120">(.+?)</td>';
	my $re_link   = '<a href="?(.+?)"?>(.+?)<\/a>';
	if ($content =~ s/<!-- TOPIC: start -->.*?${re_date}.*?${re_subj}.*?${re_link}(.*?)${re_desc}(.*?)$//is) {
		my ($time, $subj, $link, $name, $imgs, $desc, $comm) = (sprintf('%04d/%02d/%02d %02d:%02d', $1,$2,$3,$4,$5), $6, $7, $8, $9, $10, $11);
		($desc, $subj) = map { s/[\r\n]+//g; s/<br>/\n/g; $_ = $self->rewrite($_); } ($desc, $subj);
		my $item = { 'time' => $time, 'description' => $desc, 'subject' => $subj, 'link' => $res->request->uri->as_string, 'images' => [], 'comments' => [] , 'name' => $name, 'name_link' => $self->absolute_url($link, $base)};
		foreach my $image ($imgs =~ /<td width=130[^<>]*>(.*?)<\/td>/g) {
			next unless ($image =~ /<a [^<>]*'show_picture.pl\?img_src=(.*?)'[^<>]*><img src=([^ ]*) border=0>/);
			push(@{$item->{'images'}}, {'link' => $self->absolute_url($1, $base), 'thumb_link' => $self->absolute_url($2, $base)});
		}
		while ($comm =~ s/.*?${re_c_date}.*?${re_link}.*?${re_c_desc}.*?<\/table>//is){
			my ($time, $link, $name, $desc) = (sprintf('%04d/%02d/%02d %02d:%02d', $1,$2,$3,$4,$5), $6, $7, $8);
			($name, $desc) = map { s/[\r\n]+//g; s/<br>/\n/g; $_ = $self->rewrite($_); } ($name, $desc);
			push(@{$item->{'comments'}}, {'time' => $time, 'link' => $self->absolute_url($link, $base), 'name' => $name, 'description' => $desc});
		}
		push(@items, $item);
	}
	return @items;
}

sub parse_view_diary {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '<td ALIGN=center ROWSPAN=2 NOWRAP WIDTH=95 bgcolor=#FFD8B0>(\d{4})年(\d{2})月(\d{2})日<br>(\d{1,2}):(\d{2})</td>';
	my $re_subj = '<td BGCOLOR=#FFF4E0 WIDTH=430>&nbsp;(.+?)</td>';
	my $re_desc = '<td CLASS=h12>(.+?)</td>';
#	my $re_c_date = '<td rowspan="2" align="center" width="95" bgcolor="#f2ddb7" nowrap>\n(\d{4})年(\d{2})月(\d{2})日<br>(\d{1,2}):(\d{2})<br>';
	my $re_c_date = '<td rowspan="2" align="center" width="95" bgcolor="#f2ddb7" nowrap>\n(\d{4})年(\d{2})月(\d{2})日<br>(\d{1,2}):(\d{2})';
	my $re_link   = '<a href="?(.+?)"?>(.+?)<\/a>';
	if ($content =~ s/<tr VALIGN=top>.*?${re_date}.*?${re_subj}(.*?)${re_desc}(.+)//is) {
		my ($time, $subj, $imgs, $desc, $comm) = (sprintf('%04d/%02d/%02d %02d:%02d', $1,$2,$3,$4,$5), $6, $7, $8, $9);
		($desc, $subj) = map { s/[\r\n]+//g; s/<br>/\n/g; $_ = $self->rewrite($_); } ($desc, $subj);
		my $item = { 'time' => $time, 'description' => $desc, 'subject' => $subj, 'link' => $res->request->uri->as_string, 'images' => [], 'comments' => [] };
		foreach my $image ($imgs =~ /<td width=130[^<>]*>(.*?)<\/td>/g) {
			next unless ($image =~ /<a [^<>]*'show_picture.pl\?img_src=(.*?)'[^<>]*><img src=([^ ]*) border=0>/);
			push(@{$item->{'images'}}, {'link' => $self->absolute_url($1, $base), 'thumb_link' => $self->absolute_url($2, $base)});
		}
		while ($comm =~ s/.*?${re_c_date}.*?${re_link}.*?${re_desc}.*?<\/table>//is){
			my ($time, $link, $name, $desc) = (sprintf('%04d/%02d/%02d %02d:%02d', $1,$2,$3,$4,$5), $6, $7, $8);
			($name, $desc) = map { s/[\r\n]+//g; s/<br>/\n/g; $_ = $self->rewrite($_); } ($name, $desc);
			push(@{$item->{'comments'}}, {'time' => $time, 'link' => $self->absolute_url($link, $base), 'name' => $name, 'description' => $desc});
		}
		push(@items, $item);
	}
	return @items;
}

sub parse_view_message {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base      = $res->request->uri->as_string;
	my $content   = $res->content;
	my $item      = undef;
	my $re_link   = '<a href="(.+?)">(.+?)<\/';
	my $re_date   = '(\d{4})年(\d{2})月(\d{2})日&nbsp;&nbsp;(\d{1,2}):(\d{2})';
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=555>(.*?)<\/table>/s) {
		my $message = $1;
		my @rows = split(/<\/tr>/, $message, 4);
		my $image = $1 if ($rows[0] =~ /<td ALIGN=center.*?>.*?<img SRC="(.*?)" border=0>.*?<\/td>/i);
		my ($link, $name) = ($1, $2) if ($rows[0] =~ /<td BGCOLOR=#FFF4E0.*?>.*?${re_link}.*?td>/i);
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
	return unless ($res and $res->is_success);
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
	my @items   = grep { $_ and $_->{'__action__'} =~ /\Qadd_diary.pl\E/ } $self->parse_standard_form();
	return @items;
}

sub parse_add_diary_confirm {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base      = $res->base->as_string;
	my $content   = $res->content;
	my @items     = ();
	my $succeed   = '作成が完了しました。';
	if ($content =~ /<table BORDER=0 CELLSPACING=0 CELLPADDING=5>(.*?)<\/form>/s) {
		$content = $1;
		if (index($content, $succeed) != -1) {
			my $link = ($content =~ /<form action="(.*?)">/) ? $self->absolute_url($1, $base) : undef;
			my $subj = $self->rewrite($content);
			$subj =~ s/[\r\n]+//g;
			push(@items, {'subject' => $subj, 'result' => 1, 'link' => $link });
		}
	}
	return @items;
}

sub parse_delete_diary_preview {
	my $self    = shift;
	my @items   = grep { $_ and $_->{'__action__'} =~ /\Q_diary.pl\E/ } $self->parse_standard_form();
	return @items;
}

sub parse_delete_diary_confirm {
	my $self    = shift;
	return $self->parse_list_diary(@_);
}

sub parse_edit_diary_preview {
	my $self    = shift;
	my @items   = grep { $_ and $_->{'__action__'} =~ /\Q_diary.pl\E/ } $self->parse_standard_form();
	return @items;
}

sub parse_edit_diary_image {
	my $self    = shift;
	my @items   = ();
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	foreach my $photo ($content =~ /<td bgcolor="#f2ddb7">.*?<\/tr>/gs) {
		my $subj = ($photo =~ /<font color="#996600">(.*?)<\/td>/) ? $1 : next;
		my ($thumb, $link) = ($photo =~ /<img src="([^\n]*?)"><br>\n<a href="([^\n]*?)">削除<\/a>/) ? ($1, $2) : next;
		my $item = {
			'subject' => $self->rewrite($subj),
			'link' => $self->absolute_url($link, $base),
			'thumb_link' => $self->absolute_url($thumb, $base),
		};
		push(@items, $item);
	}
	return @items;
}

sub parse_edit_diary_confirm {
	my $self    = shift;
	return $self->parse_list_diary(@_);
}

sub parse_send_message_preview {
	my $self    = shift;
	my @items   = grep { $_ and $_->{'__action__'} =~ /\Qsend_message.pl\E/ } $self->parse_standard_form();
	return @items;
}

sub parse_send_message_confirm {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base      = $res->base->as_string;
	my $content   = $res->content;
	my @items     = ();
	my $succeed   = '<b>送信完了</b>しました。';
	if ($content =~ /<tr>[^\n]*?<img src=[^ ]*?\/mail_send.gif WIDTH=25 HEIGHT=28>(.*?)<\/tr>/s) {
		$content = $1;
		if (index($content, $succeed) != -1) {
			my $item = { 'subject' => $self->rewrite($succeed), 'result' => 1 };
			if ($content =~ /<a href=(banner.pl\?[^ ]*) class="img"><img src=([^ ]*?) [^<>]*? alt='([^']*)'>/) { #'{
				$item->{'banner'} = {
					'link'    => $self->absolute_url($1, $base),
					'image'   => $self->absolute_url($2, $base),
					'subject' => $self->rewrite($3),
				};
			}
			push(@items, $item)
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
	return $self->get_standard_data('parse_information', 'home.pl', @_);
}

sub get_calendar { my $self = shift; return $self->get_show_calendar(@_); }
sub get_calendar_term { my $self = shift; return $self->get_show_calendar_term(@_); }
sub get_calendar_next { my $self = shift; return $self->get_show_calendar_next(@_); }
sub get_calendar_previous { my $self = shift; return $self->get_show_calendar_previous(@_); }

sub get_community_id {
	my $self = shift;
	return $self->get_standard_data('parse_community_id', qr/view_community\.pl/, @_);
}

sub get_list_bbs {
	my $self    = shift;
	my $url     = 'list_bbs.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	return $self->get_standard_data('parse_list_bbs', qr/list_bbs\.pl/, $url, $refresh);
}

sub get_list_bbs_next {
	my $self    = shift;
	my $url     = 'list_bbs.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	$self->set_response($url, $refresh) or return;
	return $self->parse_list_bbs_next();
}

sub get_list_bbs_previous {
	my $self    = shift;
	my $url     = 'list_bbs.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	$self->set_response($url, $refresh) or return;
	return $self->parse_list_bbs_previous();
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

sub get_list_diary_monthly_menu {
	my $self = shift;
	my $url  = 'list_diary.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_diary_monthly_menu();
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

sub get_list_member {
	my $self    = shift;
	my $url     = 'list_member.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	return $self->get_standard_data('parse_list_member', qr/list_member\.pl/, $url, $refresh);
}

sub get_list_member_next {
	my $self    = shift;
	my $url     = 'list_member.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	$self->set_response($url, $refresh) or return;
	return $self->parse_list_member_next();
}

sub get_list_member_previous {
	my $self    = shift;
	my $url     = 'list_member.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	$self->set_response($url, $refresh) or return;
	return $self->parse_list_member_previous();
}

sub get_list_message {
	my $self = shift;
	my $url  = 'list_message.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_message();
}

sub get_list_outbox {
	my $self = shift;
	my $url  = 'list_message.pl?box=outbox';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_outbox();
}

sub get_list_request {
	my $self = shift;
	my $url  = 'list_request.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_list_request();
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

sub get_new_bbs_next {
	my $self = shift;
	my $url  = 'new_bbs.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_bbs_next();
}

sub get_new_bbs_previous {
	my $self = shift;
	my $url  = 'new_bbs.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_bbs_previous();
}

sub get_new_comment {
	my $self = shift;
	my $url  = 'new_comment.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_new_comment();
}

sub get_new_diary { my $self = shift; return $self->get_search_diary(@_); }
sub get_new_diary_next { my $self = shift; return $self->get_search_diary_next(@_); }
sub get_new_diary_previous { my $self = shift; return $self->get_search_diary_previous(@_); }

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

sub get_release_info {
	my $self = shift;
	my $url  = 'release_info.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_release_info();
}

sub get_self_id {
	my $self = shift;
	my $url  = 'show_profile.pl';
	$self->set_response($url, @_) or return;
	return $self->parse_self_id();
}

sub get_search_diary {
	my $self    = shift;
	my $url     = 'search_diary.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'keyword');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'keyword'}) and length($param{'keyword'}) and $url !~ /[\?\&]keyword=/) {
		$param{'keyword'} =~ s/([^\w ])/'%' . unpack('H2', $1)/eg;
		$param{'keyword'} =~ tr/ /+/;
		$url .= ($url =~ /\?/) ? "&keyword=$param{'keyword'}" : "?keyword=$param{'keyword'}";
	}
	@_ = grep { defined($_) } ($url, $refresh);
	$self->set_response(@_) or return;
	return $self->parse_search_diary();
}

sub get_search_diary_next {
	my $self = shift;
	my $url     = 'search_diary.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'keyword');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'keyword'}) and length($param{'keyword'}) and $url !~ /[\?\&]keyword=/) {
		$param{'keyword'} =~ s/([^\w ])/'%' . unpack('H2', $1)/eg;
		$param{'keyword'} =~ tr/ /+/;
		$url .= ($url =~ /\?/) ? "&keyword=$param{'keyword'}" : "?keyword=$param{'keyword'}";
	}
	$self->set_response($url, $refresh) or return;
	return $self->parse_search_diary_next();
}

sub get_search_diary_previous {
	my $self = shift;
	my $url     = 'search_diary.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'keyword');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'keyword'}) and length($param{'keyword'}) and $url !~ /[\?\&]keyword=/) {
		$param{'keyword'} =~ s/([^\w ])/'%' . unpack('H2', $1)/eg;
		$param{'keyword'} =~ tr/ /+/;
		$url .= ($url =~ /\?/) ? "&keyword=$param{'keyword'}" : "?keyword=$param{'keyword'}";
	}
	$self->set_response($url, $refresh) or return;
	return $self->parse_search_diary_previous();
}

sub get_show_calendar {
	my $self = shift;
	my $url  = 'show_calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_calendar();
}

sub get_show_calendar_term {
	my $self = shift;
	my $url  = 'show_calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_show_calendar_term();
}

sub get_show_calendar_next {
	my $self = shift;
	my $url  = 'show_calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_show_calendar_next();
}

sub get_show_calendar_previous {
	my $self = shift;
	my $url  = 'show_calendar.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_show_calendar_previous();
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

sub get_show_friend_outline {
	my $self = shift;
	my $url  = shift or return undef;
	$self->set_response($url, @_) or return undef;
	return $self->parse_show_friend_outline();
}

sub get_show_friend_profile {
	my $self = shift;
	my $url  = shift or return undef;
	$self->set_response($url, @_) or return undef;
	return $self->parse_show_friend_profile();
}

sub get_view_bbs {
	my $self = shift;
	my $url  = shift or return;
	$self->set_response($url, @_) or return undef;
	return $self->parse_view_bbs();
}

sub get_view_diary {
	my $self = shift;
	my $url  = shift or return;
	$self->set_response($url, @_) or return undef;
	return $self->parse_view_diary();
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
	my %form  = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;
	my $url   = 'add_diary.pl';
	my @files = qw(photo1 photo2 photo3);
	# POSTキー未取得、または写真があればプレビュー投稿
	if (not $form{'post_key'} or grep { $form{$_} } @files) {
		my @forms = grep {$_->{'submit'} eq 'confirm'} $self->get_add_diary_preview(%form);
		return 0 if ($self->response->is_error);
		return 0 unless (@forms);
		%form = %{$forms[0]};
		$self->log("[info] プレビューページを取得しました。\n");
		$self->dumper_log(\%form);
	}
	# 投稿
	$form{'submit'} = 'confirm';
	$self->post_add_diary(%form) or return;
	return $self->parse_add_diary_confirm();
}

sub get_delete_diary_preview {
	my $self        = shift;
	my %form        = @_;
	$self->post_delete_diary(%form) or return;
	return $self->parse_delete_diary_preview();
}

sub get_delete_diary_confirm {
	my $self  = shift;
	my %form  = @_;
	# 投稿
	$form{'submit'} = 'confirm';
	$self->post_delete_diary(%form) or return;
	return $self->parse_delete_diary_confirm();
}

sub get_edit_diary_preview {
	my $self = shift;
	my $url  = shift or return undef;
	$self->set_response($url, @_) or return undef;
	return $self->parse_edit_diary_preview();
}

sub get_edit_diary_image {
	my $self = shift;
	my $url  = shift or return undef;
	$self->set_response($url, @_) or return undef;
	return $self->parse_edit_diary_image();
}

sub get_edit_diary_confirm {
	my $self  = shift;
	my %form  = @_;
	# 投稿
	$form{'submit'} = 'main';
	$self->post_edit_diary(%form) or return;
	return $self->parse_edit_diary_confirm();
}

sub get_send_message_preview {
	my $self = shift;
	my %form = @_;
	$form{'submit'} = 'main';
	$self->post_send_message(%form) or return;
	return $self->parse_send_message_preview();
}

sub get_send_message_confirm {
	my $self = shift;
	my %form = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;
	$form{'submit'} = 'confirm';
	$form{'yes'}    = '　送　信　' unless ($form{'yes'});
	#post key未取得ならプレビュー投稿
	if (not $form{'post_key'} or not $form{'yes'}) {
		my @forms = grep {$_->{'submit'} eq 'confirm'} $self->get_send_message_preview(%form);
		return 0 if ($self->response->is_error);
		return 0 unless (@forms);
		%form = %{$forms[0]};
		$self->log("[info] プレビューページを取得しました。\n");
		$self->dumper_log(\%form);
	}
	# 送信
	$self->post_send_message(%form) or return;
	return $self->parse_send_message_confirm();
}

sub absolute_url {
	my $self = shift;
	my $url  = shift;
	my $base = (@_) ? shift : $self->{'mixi'}->{'base'};
	return undef unless (length($url));
	$url     =~ s/^"(.*)"$/$1/ or $url =~ s/^'(.*)'$/$1/;
	$url     .= '.pl' if ($url and $url !~ /[\/\.]/);
	return URI->new($url)->abs($base)->as_string;
}

sub absolute_linked_url {
	my $self = shift;
	my $url  = shift;
	return $url unless ($url and $self->response());
	my $base = $self->response->base->as_string;
	return $self->absolute_url($url, $base);
}

sub query_sorted_url {
	my $self = shift;
	my $url  = shift;
	return undef unless ($url);
	if ($url =~ s/\?(.*)$//) {
		my $qurey_string = join('&', map {join('=', @{$_})}
			map { $_->[1] =~ s/%20/+/g if @{$_} == 2; $_; }
			sort {$a->[0] cmp $b->[0]}
			map {[split(/=/, $_, 2)]} split(/&/, $1));
		$url = "$url?$qurey_string";
	}
	return $url;
}

sub enable_cookies {
	my $self = shift;
	unless ($self->cookie_jar) {
		my $cookie = sprintf('cookie_%s_%s.txt', $$, time);
		$self->cookie_jar(HTTP::Cookies->new(file => $cookie, ignore_discard => 1));
		$self->log("[info] Cookieを有効にしました。\n");
	}
	return $self;
}

sub save_cookies {
	my $self = shift;
	my $file = shift;
	my $info = '';
	my $result = 0;
	if (not $self->cookie_jar) {
		$info = "[error] Cookieが無効です。\n";
	} elsif (not $file) {
		$info = "[error] Cookieを保存するファイル名が指定されませんでした。\n";
	} else {
		$info = "[info] Cookieを\"${file}\"に保存します。\n";
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
		$info = "[error] Cookieを読み込むファイル名が指定されませんでした。\n";
	} elsif (not $file) {
		$info = "[error] Cookieファイル\"${file}\"が存在しません。\n";
	} else {
		$info = "[info] Cookieを\"${file}\"から読み込みます。\n";
		$self->enable_cookies;
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
	my @logs = @_;
	if (not defined($self->{'mixi'}->{'dumper'})) {
		eval "use Data::Dumper";
		$self->{'mixi'}->{'dumper'} = ($@) ? 0 : Data::Dumper->can('Dumper');
		$self->log("[warn] Data::Dumper is not available : $@\n") unless ($self->{'mixi'}->{'dumper'});
	}
	if ($self->{'mixi'}->{'dumper'}) {
		local $Data::Dumper::Indent = 1;
		my $log = &{$self->{'mixi'}->{'dumper'}}([@logs]);
		$log =~ s/\n/\n  /g;
		$log =~ s/\s+$/\n/s;
		return $self->log("  $log");
	} else {
		return $self->log("  [dumper] " . join(', ', @logs) . "\n");
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
		elsif ($log =~ /^\[warn\]/)     { print $log; }
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
	$str =~ s/&($re_target|#x([0-9a-z]+));/defined($unescaped{$1}) ? $unescaped{$1} : defined($2) ? chr(hex($2)) : "&$1;"/ige;
#	$str =~ s[&(.*?);]{
#		local $_ = lc($1);
#		/^($re_target)$/  ? $unescaped{$1} :
#		/^#x([0-9a-f]+)$/ ? chr(hex($1)) :
#		$_
#	}gex;
	return $str;
}

sub remove_tag {
	my $self = shift;
	my $str  = shift;
	my $re_standard_tag = q{[^"'<>]*(?:"[^"]*"[^"'<>]*|'[^']*'[^"'<>]*)*(?:>|(?=<)|$(?!\n))};
	my $re_comment_tag  = '<!(?:--[^-]*-(?:[^-]+-)*?-(?:[^>-]*(?:-[^>-]+)*?)??)*(?:>|$(?!\n)|--.*$)';
	my $re_html_tag     = qq{$re_comment_tag|<$re_standard_tag};
	$str =~ s/$re_html_tag//g;
	return $str;
}

sub remove_diary_tag {
	my $self = shift;
	my $str  = shift;
	my $re_diary_tag = join('|', 
		q{<a HREF="[^"]*" target="_blank">},
		q{<a href="[^"]*" onClick="MM_openBrWindow\([^"]*\)">},
		q{<img alt=写真 src=\S* border=0>},
		q{<span (?:class|style)="[^"]*">},
		q{<(?:blockquote|u|em|strong)>},
		q{<\/(?:a|blockquote|u|em|span|strong)>}
	);
	$str =~ s/$re_diary_tag//g;
	return $str;
}

sub redirect_ok {
	return 1;
}

sub get_standard_data {
	# default url is pased, so url is not necessary.
	my $self    = shift;
	my $parser  = shift;
	my $def_url = shift;                                    # defined url
	my $url     = shift if (@_ and $_[0] ne 'refresh');     # specified url
	if (defined($def_url) and ref($def_url) eq 'Regexp') {
		return unless (defined($url) and length($url));
		return unless ($url =~ $def_url);
	} elsif (not (ref($url) eq '' and length($url))) {
		$url = $def_url;
	}
	$self->abort("url \"$url\" is invalid.") unless (defined($url) and length($url));     # invalid url
	$self->can($parser) or $self->abort("parser \"$parser\" is not available.");          # invalid method
	$self->set_response($url, @_) or $self->abort("set_response failed.");                # request can not processed
	return $self->$parser();
}

sub parse_standard_history {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = '(?:(\d{4})年)?(\d{2})月(\d{2})日 (\d{1,2}):(\d{2})';
	my $re_name = '\(([^\r\n]*)\)';
	my $re_link = '<a href="?(.+?)"?>(.+?)\s*<\/a>';
	if ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>(.+?)<\/table>/s) {
		$content = $1;
		my @today = reverse((localtime)[3..5]);
		$today[0] += 1900;
		$today[1] += 1;
		while ($content =~ s/<tr bgcolor=#FFFFFF>.*?${re_date}.*?${re_link}\s*${re_name}.*?<\/tr>//is) {
			my @date = ($1, $2, $3, $4, $5);
			$date[0] = ($date[1] > $today[1]) ? $today[0] - 1 : $today[0] if (not defined($date[0]));
			my $time = sprintf('%04d/%02d/%02d %02d:%02d', @date);
			my $subj = $self->rewrite($7);
			my $name = $self->rewrite($8);
			my $link = $self->absolute_url($6, $base);
			push(@items, {'time' => $time, 'subject' => $subj, 'name' => $name, 'link' => $link});
		}
	}
	return @items;
}

sub parse_standard_history_next {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5>[^\r\n]*?<a href=["']?([^>]+?)['"]?>([^<>]+)<\/a><\/td><\/tr>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_standard_history_previous {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->request->uri->as_string;
	my $content  = $res->content;
	return unless ($content =~ /<td ALIGN=right BGCOLOR=#EED6B5><a href=["']?(.+?)['"]?>([^<>]+)<\/a>[^\r\n]*?<\/td><\/tr>/);
	my $subject  = $2;
	my $link     = $self->absolute_url($1, $base);
	my $previous = {'link' => $link, 'subject' => $2};
	return $previous;
}

sub parse_standard_form {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($res->is_success and $content =~ /<tr>.*?<img src=["']?http:\/\/[^<> ]*\/alt.gif['" ].*?>(.*?)<\/tr>/s) {
		my $message = $1;
		$message =~ s/\n//g;
		$message =~ s/<br>|<br ?\/>|<\/br>/\n/g;
		$res->code(400);
		$res->message($self->rewrite($message));
		return;
	}
	while ($content =~ s/(<form (?:"[^"]*"|'[^']*'|[^'"<>]*)*>)(.*?)<\/form>//is) {
		my $tag    = $1;
		my $form   = $2;
		my $action = ($tag =~ /\baction=("[^"]*"|'[^']*'|[^'"<> ]*)/) ? $1 : "";
		$action    =~ s/^"(.*)"$/$1/s or $action =~ s/^'(.*)'$/$1/s;
		my $item   = {'__action__' => $self->absolute_url($action, $base)};
		foreach my $tag ($form =~ /<input (?:"[^"]*"|'[^']*'|[^'"<>]*)*>/g) {
			my $name = ($tag =~ /\bname=("[^"]*"|'[^']*'|[^'"<> ]*)/) ? $1 : "";
			my $value = ($tag =~ /\bvalue=("[^"]*"|'[^']*'|[^'"<> ]*)/) ? $1 : "";
			($name, $value) = map { s/^"(.*)"$/$1/s or s/^'(.*)'$/$1/s; $_ } ($name, $value);
			$item->{$name} = $self->rewrite($value) if (length($name));
		}
		while ($form =~ s/<textarea ((?:"[^"]*"|'[^']*'|[^'"<>]*)*)>(.*?)<\/textarea.*?>//s) {
			my ($attrs, $value) = ($1, $2);
			my $name = ($attrs =~ /\bname=("[^"]*"|'[^']*'|[^'"<> ]*)/) ? $1 : "";
			($name) = map { s/^"(.*)"$/$1/s or s/^'(.*)'$/$1/s; $_ } ($name);
			$item->{$name} = $self->rewrite($value) if (length($name));
		}
		push(@items, $item);
	}
	return @items;
}


sub set_response {
	my $self    = shift;
	my $url     = shift;
	my $refresh = (@_ and defined($_[0]) and $_[0] eq 'refresh') ? 1 : 0;
	my $latest  = ($self->response) ? $self->response->request->uri->as_string : undef;
	$url        = $self->query_sorted_url($self->absolute_url($url));
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
	my @fields   = qw(submit diary_title diary_body photo1 photo2 photo3 orig_size packed post_key);
	my @required = qw(submit diary_title diary_body);
	my @files    = qw(photo1 photo2 photo3);
	my %label    = ('diary_title' => '日記のタイトル', 'diary_body' => '日記の本文', 'photo1' => '写真1', 'photo2' => '写真2', 'photo3' => '写真3', orig_size => '圧縮指定', packed => '送信データ', 'post_key' => '送信キー');
	my @errors;
	# データの生成とチェック
	my %form     = map { $_ => $values{$_} } @fields;
	push @errors, map { "$label{$_}を指定してください。" } grep { not $form{$_} } @required;
	if ($form{'submit'} eq 'main') {
		# プレビュー用の追加処理
		foreach my $file (@files) {
			next unless ($form{$file});
			if (not -f $form{$file}) {
				push @errors, "[info] $label{$file}のファイル\"$form{$file}\"がありません。\n" ;
			} else {
				$form{$file} = [$form{$file}];
			}
		}
	}
	if (@errors) {
		$self->log(join('', @errors));
		return undef;
	}
	return $self->post($url, %form);
}

sub post_edit_diary {
	my $self      = shift;
	my %values    = @_;
	$self->dumper_log(\%values);
	$values{'id'} = $values{'diary_id'} if (not $values{'id'} and defined($values{'diary_id'}));
	my $url       = exists($values{'__action__'}) ? $values{'__action__'} : 'edit_diary.pl?id=' . $values{'id'};
	my @fields    = qw(submit diary_title diary_body photo1 photo2 photo3 submit);
	my @required  = qw(submit diary_title diary_body);
	my @files     = qw(photo1 photo2 photo3);
	my %label     = ('id' => '日記ID', 'diary_title' => '日記のタイトル', 'diary_body' => '日記の本文', 'photo1' => '写真1', 'photo2' => '写真2', 'photo3' => '写真3');
	my @errors;
	# データの生成とチェック
	my %form     = map { $_ => $values{$_} } @fields;
	push @errors, "[error] $label{'id'}を指定してください。\n" if ($url !~ /[\?&]id=\d+/);
	push @errors, map { "[error] $label{$_}を指定してください。\n" } grep { not $form{$_} } @required;
	# ファイル追加処理
	foreach my $file (@files) {
		next unless ($form{$file});
		if (not -f $form{$file}) {
			push @errors, "[info] $label{$file}のファイル\"$form{$file}\"がありません。\n" ;
		} else {
			$form{$file} = [$form{$file}];
		}
	}
	if (@errors) {
		$self->log(join('', @errors));
		return undef;
	}
	return $self->post($url, %form);
}

sub post_delete_diary {
	my $self     = shift;
	my %values   = @_;
	my $url      = 'delete_diary.pl';
	my @fields   = qw(submit id post_key);
	my @required = qw(id post_key);
	my %label    = ('id' => '日記ID', 'post_key' => '送信キー');
	# データの生成とチェック
	my %form     = map {$_ => $values{$_}} @fields;
	$form{'id'}  = $values{'diary_id'} if (not $form{'id'} and defined($values{'diary_id'}));
	$form{'id'}  = $1 if ($values{'__action__'} and $values{'__action__'} =~ /delete_diary.pl?id=(\d+)/);
	my @errors   = map { "$label{$_}を指定してください。" } grep { not $form{$_} } @required;
	if (@errors) {
		$self->log(map { "[warn] $_\n" } @errors);
		return undef;
	}
	$url .= "?id=" . delete($form{'id'});
	return $self->post($url, %form);
}

sub post_send_message {
	my $self     = shift;
	my %values   = @_;
	my $url      = exists($values{'__action__'}) ? $values{'__action__'} : 'send_message.pl?id=' . $values{'id'};
	my @fields   = qw(submit subject body post_key yes no);
	my @required = qw(submit subject body);
	my %label    = ('id' => '受信者のID', 'subject' => 'メッセージのタイトル', 'body' => 'メッセージの本文', 'post_key' => '送信キー');
	my %form     = map { $_ => $values{$_} } @fields;
	my @errors   = map { "$label{$_}を指定してください。" } grep { not $form{$_} } @required;
	push(@errors, "$label{'id'}を指定してください。") if ($url !~ /[\?&]id=\d+/);
	if (@errors) {
		$self->log(map { "[warn] $_\n" } @errors);
		return undef;
	}
	delete($form{'no'}) if ($form{'yes'} and $form{'no'});  # プレビューを解析すると'yes'、'no'が両方入るため、択一
	return $self->post($url, %form);
}

sub convert_login_time {
	my $self = shift;
	my $time = @_ ? shift : 0;
	if ($time =~ /^\d+$/) { 1; }
	elsif ($time =~ /^(\d+)分/)   { $time = $1 * 60; }
	elsif ($time =~ /^(\d+)時間/) { $time = $1 * 60 * 60; }
	elsif ($time =~ /^(\d+)日/)   { $time = $1 * 60 * 60 * 24; }
	else { $self->log("[error] ログイン時刻\"$time\"を解析できませんでした。\n"); }
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

		&{$logger}("mixiにログインできるメールアドレスとパスワードを指定してください。\n");
		&{$logger}("[usage] perl -MWWW::Mixi -e \"WWW::Mixi::test('mail\@address', 'password');\"\n");
		exit 1;
	}
	my ($result, $response) = ();
	# オブジェクトの生成
	my $mixi = &test_new($mail, $pass, $logger);            # オブジェクトの生成
	$mixi->test_login;                                      # ログイン
	$mixi->test_get;                                        # GET（トップページ）
	$mixi->test_scenario;                                   # 主要データの取得と解析
	$mixi->test_get_add_diary_preview;                      # 日記のプレビュー
	$mixi->test_save_and_read_cookies;                      # Cookieの読み書き
	# 終了
	$mixi->log("終了しました。\n");
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
			elsif ($log =~ /^\[warn\]/)     { print OUT $log; print $log; }
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
	&{$logger}("オブジェクトを生成します。\n");
	my $mixi = eval "WWW::Mixi->new('$mail', '$pass', '-log' => \$logger)";
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $mixi) {
		$error = "[error] 不明なエラーです。\n";
	} elsif (not $mixi->{'mixi'}) {
		$error = "[error] mixi関連情報を設定できませんでした。\n";
	}
	if ($error) {
		&{$logger}({}, "オブジェクトを生成できませんでした。\n", $error);
		exit 8;
	}
	$mixi->delay(0);
	$mixi->env_proxy;
	return $mixi;
}

sub test_login {
	my $mixi = shift;
	my $error = '';
	$mixi->log("mixiにログインします。\n");
	my ($result, $response) = eval '$mixi->login';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $result) {
		if (not $response->is_success) {
			$error = sprintf("[error] %d %s\n", $response->code, $response->message);
			$error .= "[info] Webアクセスにプロキシが必要な時は、環境変数HTTP_PROXYをセットしてから再試行してください。\n" unless($ENV{'HTTP_PROXY'});
		} elsif ($mixi->is_login_required($response)) {
			$error = "[error] " . $mixi->is_login_required($response) . "\n";
		} elsif (not $mixi->session) {
			$error = "[error] セッションIDを取得できませんでした。\n";
		} elsif (not $mixi->stamp) {
			$error = "[error] セッションスタンプを取得できませんでした。\n";
		} elsif (not $mixi->session) {
			$error = "[error] リフレッシュURLを取得できませんでした。\n";
		}
	}
	if ($error) {
		$mixi->log("ログインできませんでした。\n", $error);
		$mixi->dumper_log($response);
		exit 8;
	} else {
		$mixi->log('[info] セッションIDは"' . $mixi->session . "\"です。\n");
	}
}

sub test_get {
	my $mixi = shift;
	my $error = '';
	$mixi->log("トップページを取得します。\n");
	my $response = eval '$mixi->get("home")';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $response->is_success) {
		$error = sprintf("[error] %d %s\n", $response->code, $response->message);
		$error .= "[info] Webアクセスにプロキシが必要な時は、環境変数HTTP_PROXYをセットしてから再試行してください。\n" unless($ENV{'HTTP_PROXY'});
	} elsif ($mixi->is_login_required($response)) {
		$error = "[error] " . $mixi->is_login_required($response) . "\n";
	}
	if ($error) {
		$mixi->log("トップページの取得に失敗しました。\n", $error);
		$mixi->dumper_log($response);
		exit 8;
	}
}

sub test_record {
	my $mixi = shift;
	$mixi->{'__test_record'} = {} unless (ref($mixi->{'__test_record'}) eq 'HASH');
	if (@_ == 0) {
		return sort { $a cmp $b } (keys(%{$mixi->{'__test_record'}}));
	} elsif (@_ == 1) {
		my $key = shift;
		return $mixi->{'__test_record'}->{$key};
	} else {
		my %args = @_;
		map { $mixi->{'__test_record'}->{$_} = $args{$_} } keys(%args);
		return 1;
	}
}

sub test_scenario {
	my $mixi = shift;
	my @tests = (
		# 引数不要のもの
		'main_menu'               => {'label' => 'メインメニュー'},
		'banner'                  => {'label' => 'バナー'},
		'tool_bar'                => {'label' => 'ツールバー'},
		'information'             => {'label' => '管理者からのお知らせ'},
		'list_bookmark'           => {'label' => 'お気に入り'},
		'list_comment'            => {'label' => '最近のコメント'},
		'list_community'          => {'label' => 'コミュニティ一覧'},
		'list_community_next'     => {'label' => 'コミュニティ一覧(次)'},
		'list_community_previous' => {'label' => 'コミュニティ一覧(前)', 'url' => sub { return $_[0]->test_record('list_community_next')}},
		'list_diary'              => {'label' => '日記'},
		'list_diary_capacity'     => {'label' => '日記容量'},
		'list_diary_next'         => {'label' => '日記(次)'},
		'list_diary_previous'     => {'label' => '日記(前)', 'url' => sub { return $_[0]->test_record('list_diary_next')}},
		'list_diary_monthly_menu' => {'label' => '日記月別ページ'},
		'list_friend'             => {'label' => '友人・知人一覧'},
		'list_friend_next'        => {'label' => '友人・知人一覧(次)'},
		'list_friend_previous'    => {'label' => '友人・知人一覧(前)', 'url' => sub { return $_[0]->test_record('list_friend_next')}},
		'list_message'            => {'label' => '受信メッセージ'},
		'list_outbox'             => {'label' => '送信メッセージ'},
		'list_request'            => {'label' => '承認待ちの友人'},
		'new_album'               => {'label' => 'マイミクシィ最新アルバム'},
		'new_bbs'                 => {'label' => 'コミュニティ最新書き込み'},
		'new_bbs_next'            => {'label' => 'コミュニティ最新書き込み(次)'},
		'new_bbs_previous'        => {'label' => 'コミュニティ最新書き込み(前)', 'url' => sub { return $_[0]->test_record('new_bbs_next')}},
		'new_comment'             => {'label' => '日記コメント記入履歴'},
		'new_friend_diary'        => {'label' => 'マイミクシィ最新日記'},
		'new_friend_diary_next'   => {'label' => 'マイミクシィ最新日記(次)'},
		'new_friend_diary_previous' => {'label' => 'マイミクシィ最新日記(前)', 'url' => sub { return $_[0]->test_record('new_friend_diary_next')}},
		'new_review'              => {'label' => 'マイミクシィ最新レビュー'},
		'release_info'            => {'label' => 'リリースインフォメーション'},
		'self_id'                 => {'label' => '自分のID'},
		'search_diary'            => {'label' => '新着日記検索', 'arg' => ['keyword' => 'Mixi']},
		'search_diary_next'       => {'label' => '新着日記検索(次)', 'arg' => ['keyword' => 'Mixi']},
		'search_diary_previous'   => {'label' => '新着日記検索(前)', 'url' => sub { return $_[0]->test_record('search_diary_next')}},
		'show_calendar'           => {'label' => 'カレンダー'},
		'show_calendar_term'      => {'label' => 'カレンダーの期間'},
		'show_calendar_next'      => {'label' => 'カレンダー(次)'},
		'show_calendar_previous'  => {'label' => 'カレンダー(前)', 'url' => sub { return $_[0]->test_record('show_calendar_next')}},
		'show_log'                => {'label' => 'あしあと'},
		'show_log_count'          => {'label' => 'あしあと数'},
		'view_diary'              => {'label' => '日記(詳細)', 'url' => sub { return $_[0]->test_record('list_diary')}},
		'view_message'            => {'label' => 'メッセージ(詳細)', 'url' => sub { return $_[0]->test_record('list_message')}},
		# コミュニティ関連
		'community_id'            => {'label' => 'コミュニティID',   'url' => sub { return $_[0]->test_record('list_community')}},
		'list_bbs'                => {'label' => 'トピック一覧',     'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_bbs_next'           => {'label' => 'トピック一覧(次)', 'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_bbs_previous'       => {'label' => 'トピック一覧(前)', 'url' => sub { return $_[0]->test_record('list_bbs_next')}},
		'list_member'             => {'label' => 'メンバー一覧',     'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_member_next'        => {'label' => 'メンバー一覧(次)', 'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_member_previous'    => {'label' => 'メンバー一覧(前)', 'url' => sub { return $_[0]->test_record('list_member_next')}},
		'view_bbs'                => {'label' => 'トピック',         'url' => sub { return $_[0]->test_record('list_bbs')}},
	);
	while (@tests >= 2) {
		my ($test, $opt) = splice(@tests, 0, 2);
		my $method = "get_$test";
		my $label = $opt->{'label'};
		my $url = defined($opt->{'url'}) ? $opt->{'url'} : '';
		if (defined($url) and ref($url) eq 'CODE') {
			$url = &{$url}($mixi);
			unless ($url) {
				$mixi->log("$labelをスキップします。\n", "[warn] 参照レコードなし\n");
				next;
			}
		}
		$url = $url->{'link'} if (defined($url) and ref($url) eq 'HASH');
		my @arg = (defined($opt->{'arg'}) and ref($opt->{'arg'})) eq 'ARRAY' ? @{$opt->{'arg'}} : ();
		@arg = map { ref($_) eq 'CODE' ? &{$_}($mixi) : $_ } @arg;
		unshift(@arg, $url) if (defined($url) and ref($url) eq '' and length($url));
		$mixi->log("$labelの取得と解析をします。\n");
		my @items = eval { $mixi->$method(@arg); };
		my $error = ($@) ? $@ : ($mixi->response->is_error) ? $mixi->response->status_line : undef;
		if (defined $error) {
			$mixi->log("$labelの取得と解析に失敗しました。\n", "[error] $error\n");
			$mixi->dumper_log($mixi->response);
			exit 8;
		} else {
			if (@items) {
				$mixi->dumper_log([@items]);
				$mixi->test_record($test => $items[0]);
			} else {
				$mixi->log("[warn] レコードが見つかりませんでした。\n");
				$mixi->dumper_log($mixi->response);
			}
		}
	}
}

sub test_get_add_diary_preview {
	my $mixi = shift;
	my %diary = (
		'diary_title' => '日記タイトル',
		'diary_body'  => '日記本文',
		'photo1'      => '../logo.jpg',
		'orig_size'   => 1,
	);
	$mixi->log("日記の投稿と確認画面の解析をします。\n");
	my @items = eval '$mixi->get_add_diary_preview(%diary)';
	my $error = ($@) ? "[error] $@\n" : ($mixi->response->is_error) ? "[error] " . $mixi->response->status_line ."\n" : '';
	if ($error) {
		$mixi->log("日記の投稿と確認画面の解析に失敗しました。\n", $error);
		exit 8;
	} else {
		if (@items) {
			$mixi->dumper_log([@items]);
		} else {
			$mixi->log("[info] 確認画面のフォームが見つかりませんでした。\n");
			$mixi->dumper_log($mixi->response);
		}
	}
}

sub test_save_and_read_cookies {
	my $mixi = shift;
	my $error = '';
	# Cookieの保存
	$mixi->log("Cookieを保存します。\n");
	my $saved_str   = $mixi->cookie_jar->as_string;
	my $loaded_str  = '';
	my $cookie_file = sprintf('cookie_%s_%s.txt', $$, time);
	$_ = eval '$mixi->save_cookies($cookie_file)';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $_) {
		$error = "[error] cookieの保存が失敗しました。\n";
	}
	if ($error) {
		$mixi->log("Cookieを保存できませんでした。\n", $error);
		exit 8;
	}
	# Cookieの読込
	$mixi->log("Cookieの読込をします。\n");
	$mixi->cookie_jar->clear;
	$_ = eval '$mixi->load_cookies($cookie_file)';
	if ($@) {
		$error = "[error] $@\n";
	} elsif (not $_) {
		$error = "[error] cookieの読込が失敗しました。\n";
	} else {
		$loaded_str = $mixi->cookie_jar->as_string;
		$error = "[error] 保存したCookieと読み込んだCookieが一致しません。\n" if ($saved_str ne $loaded_str);
	}
	if ($error) {
		$mixi->log("Cookieを読込めませんでした。\n", $error);
		exit 8;
	}
	unlink($cookie_file);
}

package WWW::Mixi::RobotRules;
use vars qw($VERSION @ISA);
require WWW::RobotRules;
@ISA = qw(WWW::RobotRules::InCore);

$VERSION = sprintf("%d.%02d", q$Revision: 0.01 $ =~ /(\d+)\.(\d+)/);

sub allowed {
	return 1;
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

=head1 AUTHORS

WWW::Mixi is written by TSUKAMOTO Makio <tsukamoto@gmail.com>

Some bug fixes submitted by Topia (http://clovery.jp/), shino (http://www.freedomcat.com/), makamaka (http://www.donzoko.net/), ash.
get_ and post_add_diary, get_ and post_delete_diary, parse_list_diary and parse_new_diary contributed by DonaDona (http://hsj.jp/).
get_ and parse_view_diary contributed by shino (http://www.freedomcat.com/).
get_ and parse_list_outbox contributed by AsO (http://www.bx.sakura.ne.jp/~clan/rn/cgi-bin/index.cgi).
get_ and post_send_message contributed by noname (http://untitled.rootkit.jp/diary/).

=head1 COPYRIGHT

Copyright 2004-2005 Makio Tsukamoto.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

