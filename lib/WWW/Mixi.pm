package WWW::Mixi;

use strict;
use Carp ();
use vars qw($VERSION @ISA);

$VERSION = sprintf("%d.%02d", q$Revision: 0.48$ =~ /(\d+)\.(\d+)/);

require LWP::RobotUA;
@ISA = qw(LWP::RobotUA);
require HTTP::Request;
require HTTP::Response;

use Jcode;
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
		'logcode'  => exists($opt{'-logcode'}) ? $opt{'-logcode'} : undef,
		'log'      => exists($opt{'-log'})     ? $opt{'-log'}     : \&callback_log,
		'abort'    => exists($opt{'-abort'})   ? $opt{'-abort'}   : \&callback_abort,
		'rewrite'  => exists($opt{'-rewrite'}) ? $opt{'-rewrite'} : \&callback_rewrite,
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
	# get main menu part
	my $content_from = qq(\Q<map name=mainmenu>\E);
	my $content_till = qq(\Q</map>\E);
	return $self->log("[warn] main menu part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse main menu items
	my @tags = ($content =~ /(<area [^<>]*>)/gs);
	return $self->log("[warn] area tag is missing in main menu part.\n") unless (@tags);
	# parse each items
	foreach my $str (@tags) {
		my $tag = $self->parse_standard_tag($str);
		my $item = { 'link' => $self->absolute_url($tag->{'attr'}->{'href'}, $base), 'subject' => $self->rewrite($tag->{'attr'}->{'alt'}) };
		push(@items, $item);
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
	my @tags    = ($content =~ /(<iframe [^<>]*>)/gs);
	return $self->log("[warn] content has no iframe tags.\n") unless (@tags);
	foreach my $str (@tags) {
		my $tag = $self->parse_standard_tag($str);
		next unless ($tag->{'attr'}->{'src'} and $tag->{'attr'}->{'src'} =~ /^http:\/\/ads.mixi.jp/);
		my $item = { 'link' => $tag->{'attr'}->{'src'} };
		push(@items, $item);
		last;
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
	# get tool bar part
	my $content_from = qq(\Q<td><img src=http://img.mixi.jp/img/b_left.gif width=22 height=23></td>\E);
	my $content_till = qq(\Q<td><img src=http://img.mixi.jp/img/b_right.gif width=23 height=23></td>\E);
	return $self->log("[warn] tool bar part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse tool bar part
	while ($content =~ s/<a href=([^<> ]*?) .*?><img .*?alt=([^<> ]*?) .*?><\/a>//i) {
		my $item = { 'link' => $self->absolute_url($1, $base), 'subject' => $self->rewrite($2) };
		push(@items, $item);
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
	# get information part
	my $content_from = qq(\Q<!-- お知らせメッセージ ここから -->\E);
	my $content_till = qq(\Q<!-- お知らせメッセージ ここまで -->\E);
	return $self->log("[warn] information is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse information part
	$content =~ s/[\r\n]+//g;
	$content =~ s/<!--.*?-->//g;
	while ($content =~ s/<tr><td>(.*?)<\/td><td>(.*?)<\/td><td>(.*?)<\/td><\/tr>//i) {
		my ($subject, $linker) = ($1, $3);
		my $re_attr_val = '(?:"[^"]+"|\'[^\']+\'|[^\s<>]+)\s*';
		my $style = {};
		$subject =~ s/^.*?・<\/font>(?:&nbsp;| )//;
		while ($subject =~ s/^\s*<([^<>]*)>\s*//) {
			my $tag = lc($1);
			my ($tag_part, $attr_part) = split(/\s+/, $tag, 2);
			$style->{'font-weight'} = 'bold' if ($tag_part eq 'b');
			while ($attr_part =~ s/([^\s<>=]+)(?:=($re_attr_val))?//) {
				my ($attr, $val) = ($1, $2);
				$val =~ s/^"(.*)"$/$1/ or $val =~ s/^'(.*)'$/$1/;
				$val = $self->unescape($val);
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
	return @items;
}

sub parse_home_new_album {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->base->as_string;
	my $content  = $res->content;
	my @items    = ();
	# get new album part
	my $content_from = qq(\Qマイミクシィ最新アルバム\E);
	my $content_till = qq(\Q<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=300>\E);
	return $self->log("[warn] new album part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse new album part
	while ($content =~ s/<img src=.*?>(\d{2})月(\d{2})日.*?<a href=(.+?)>(.*?)<\/a>.*?\((.+?)\)<br CLEAR=all>//is) {
		my ($date, $link, $subj, $name) = ((sprintf('%02d/%02d', $1, $2)), $3, $4, $5);
		$subj = $self->rewrite($subj);
		$name = $self->rewrite($name);
		$link = $self->absolute_url($link, $base);
		push(@items, {'time' => $date, 'link' => $link, 'subject' => $subj, 'name' => $name});
	}
	return @items;
}

sub parse_home_new_bbs {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->base->as_string;
	my $content  = $res->content;
	my @items    = ();
	# get new bbs part
	my $content_from = qq(\Qコミュニティ最新書き込み\E);
	my $content_till = qq(\Q<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=300>\E);
	return $self->log("[warn] new bbs part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse new bbs part
	while ($content =~ s/<img src=.*?>(\d{2})月(\d{2})日.*?<a href=(.+?)>(.*?)<\/a>.*?\((.+?)\)<br CLEAR=all>//is) {
		my ($date, $link, $subj, $name) = ((sprintf('%02d/%02d', $1, $2)), $3, $4, $5);
		$subj = $self->rewrite($subj);
		$name = $self->rewrite($name);
		$link = $self->absolute_url($link, $base);
		push(@items, {'time' => $date, 'link' => $link, 'subject' => $subj, 'name' => $name});
	}
	return @items;
}

sub parse_home_new_comment {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->base->as_string;
	my $content  = $res->content;
	my @items    = ();
	# get new comment part
	my $content_from = qq(\Q日記コメント記入履歴\E);
	my $content_till = qq(\Q<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=300>\E);
	return $self->log("[warn] new comment part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse new comment part
	while ($content =~ s/<img src=.*?>(\d{2})月(\d{2})日.*?<a href=(.+?)>(.*?)<\/a>.*?\((.+?)\)<br CLEAR=all>//is) {
		my ($date, $link, $subj, $name) = ((sprintf('%02d/%02d', $1, $2)), $3, $4, $5);
		$subj = $self->rewrite($subj);
		$name = $self->rewrite($name);
		$link = $self->absolute_url($link, $base);
		push(@items, {'time' => $date, 'link' => $link, 'subject' => $subj, 'name' => $name});
	}
	return @items;
}

sub parse_home_new_friend_diary {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->base->as_string;
	my $content  = $res->content;
	my @items    = ();
	# get new friend diary part
	my $content_from = qq(\Q<td BGCOLOR=#F2DDB7 WIDTH=80 NOWRAP><font COLOR=#996600>マイミクシィ最新日記</font>\E.*?\Q</td>\E);
	my $content_till = qq(\Q<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=300>\E);
	return $self->log("[warn] new friend diary part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse new friend diary part
	while ($content =~ s/<img src=.*?>(\d{2})月(\d{2})日.*?<a href=(.+?)>(.*?)<\/a>.*?\((.+?)\)<br CLEAR=all>//is) {
		my ($date, $link, $subj, $name) = ((sprintf('%02d/%02d', $1, $2)), $3, $4, $5);
		$subj = $self->rewrite($subj);
		$name = $self->rewrite($name);
		$link = $self->absolute_url($link, $base);
		push(@items, {'time' => $date, 'link' => $link, 'subject' => $subj, 'name' => $name});
	}
	return @items;
}

sub parse_home_new_review {
	my $self     = shift;
	my $res      = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base     = $res->base->as_string;
	my $content  = $res->content;
	my @items    = ();
	if ($content =~ /マイミクシィ最新レビュー(.*?)<table BORDER=0 CELLSPACING=0 CELLPADDING=0 WIDTH=300>/s) {
		$content = $1;
		while ($content =~ s/<img src=.*?>(\d{2})月(\d{2})日.*?<a href=(.+?)>(.*?)<\/a>.*?\((.+?)\)<br CLEAR=all>//is) {
			my ($date, $link, $subj, $name) = ((sprintf('%02d/%02d', $1, $2)), $3, $4, $5);
			$subj = $self->rewrite($subj);
			$name = $self->rewrite($name);
			$link = $self->absolute_url($link, $base);
			push(@items, {'time' => $date, 'link' => $link, 'subject' => $subj, 'name' => $name});
		}
	}
	return @items;
}

sub parse_ajax_new_diary {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	my $re_date = q{(\d{1,2})月(\d{1,2})日};
	my $re_link = q{(<a (?:"[^"]*"|'[\']*'|[^>]+)*>)(.*?)<\/a>};
	my $re_name = q{\((.*?)\)};
	my @today = reverse((localtime)[3..5]);
	$today[0] += 1900;
	$today[1] += 1;
	foreach my $row ($content =~ /<div align=left>(.*?)<\/div>/isg) {
		next unless ($row =~ /$re_date … $re_link/);
		my $item           = {};
		my @date           = (undef, $1, $2);
		$item->{'link'}    = $self->absolute_url($self->parse_standard_anchor($3), $base);
		$item->{'subject'} = (defined($4) and length($4)) ? $self->rewrite($4) : '(削除)';
		$date[0]           = ($date[1] > $today[1]) ? $today[0] - 1 : $today[0] if (not defined($date[0]));
		$item->{'time'}    = sprintf('%04d/%02d/%02d', @date);
		map { $item->{$_} =~ s/^\s+|\s+$//gs } (keys(%{$item}));
		push(@items, $item);
	}
	return @items;
}

sub parse_community_id {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my $item;
	if ($content =~ /view_community.pl\?id=(\d+)/) {
		$item = $1;
	}
	return $item;
}

sub parse_edit_member {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	# get member list part
	my $content_from = qq(\Q<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>\E);
	my $content_till = qq(\Q</table>\E);
	return $self->log("[warn] member list part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# get member list
	$content =~ s/[\t\r\n]//g;
	my @rows = ($content =~ /<tr>(.*?)<\/tr>/ig);
	return $self->log("[warn] member list has no rows.\n") unless (@rows);
	# parse rows
	foreach my $row (@rows) {
		my @cols = ($row =~ /<td[^<>]*?>(.*?)<\/td>/g);
		if ($#cols >= 1 and $cols[1] =~ /<a href="([^'""<>]*?)">(.*)<\/a>/) {
			my $item = {'link' => $self->absolute_url($1, $base), 'subject' => $self->rewrite($2)};
			$item->{'date'} = "${1}/${2}/${3}" if ($cols[0] =~ /(\d{4})年(\d{4})月(\d{4})日/);
			$item->{'delete_member'}  = {'link' => $self->absolute_url($1, $base), 'subject' => $self->rewrite($2)} if ($#cols >= 2 and $cols[2] =~ /<a href="([^'""<>]*?)">(.*)<\/a>/);
			$item->{'transfer_admin'} = {'link' => $self->absolute_url($1, $base), 'subject' => $self->rewrite($2)} if ($#cols >= 3 and $cols[3] =~ /<a href="([^'""<>]*?)">(.*)<\/a>/);
			push(@items, $item);
		}
	}
	return @items;
}

sub parse_edit_member_pages {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $current = $res->request->uri->as_string;
	my $content = $res->content;
	my @items   = ();
	# get page list part
	my $content_from = qq(\Q<!-- start: page number -->\E[^\\[\\]]*\\[);
	my $content_till = qq(\\][^\\[\\]]*\Q<!-- end: page number -->\E);
	return $self->log("[warn] page list part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse rows
	$content =~ s/[\t\r\n]//g;
	while ($content =~ s/ (?:<a href=["']?([^"'<>]*)["']?>)?(\d+)(?:<\/a>)? / /) {
		my $item = {'subject' => $self->rewrite($2)};
		$item->{'link'}    = ($1) ? $self->absolute_url($1, $base) : $current;
		$item->{'current'} = ($1) ? 0 : 1;
		push(@items, $item);
	}
	return @items;
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
	my $re_desc = '<td CLASS=h120>(.*?)\n</td>';
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
	# get bookmark list part
	my $content_from = qq(\Q<img src=http://img.mixi.jp/img/q_brown2.gif WIDTH=7 HEIGHT=7>\E);
	my $content_till = qq(\Q<img src=http://img.mixi.jp/img/q_brown3.gif WIDTH=7 HEIGHT=7>\E);
	return $self->log("[warn] bookmark list part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse rows
	my @records = ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=550>(.*?)<\/table>/isg);
	return $self->log("[warn] no bookmark records found.\n") unless (@records);
	foreach my $record (@records) {
		my @lines = ($record =~ /<tr.*?>(.*?)<\/tr>/isg);
		my $item = {};
		# parse record
		($item->{'link'},    $item->{'image'})  = ($1, $2) if ($lines[0] =~ /<td (?:[^\s<>]+ )*WIDTH=90 .*?><a href="([^"]*show_friend.pl\?id=\d+)"><img src="([^"]*)".*?>/is);
		($item->{'subject'}, $item->{'gender'}) = ($1, $2) if ($lines[0] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>([^<>]*) \(([^\(\)]*)\)<\/td>/is);
		$item->{'description'} = $1 if ($lines[1] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
		$item->{'time'}        = $1 if ($lines[2] =~ /<td BGCOLOR=#FFFFFF WIDTH=140>([^<>]*?)<\/td>/is);
		# format
		foreach (qw(image link)) { $item->{$_} = $self->absolute_url($item->{$_}, $base) if ($item->{$_}); }
		foreach (qw(subject description gender)) { $item->{$_} = $self->rewrite($item->{$_}); }
		$item->{'time'} = $self->convert_login_time($item->{'time'}) if ($item->{'time'});
		push(@items, $item) if ($item->{'subject'} and $item->{'link'});
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
		'bg_orange1-.gif' => '管理者',
	};
	# get community list part
	my $content_from = qq(\Q<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>\E);
	my $content_till = qq(\Q</table>\E);
	return $self->log("[warn] community list part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# get community list rows
	my @rows = ();
	push(@rows, [$1, $2]) while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<\/tr>\s*<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is);
	return $self->log("[warn] community list has no rows.\n") unless (@rows);
	# parse each items
	foreach my $row (@rows) {
		my ($image_part, $text_part) = @{$row};
		my @images = ($image_part =~ /<td\b[^<>]*>.*?<\/td>/gi);
		my @texts  = ($text_part =~ /<td\b[^<>]*>(.*?)<\/td>/gi);
		return $self->log("[warn] image is missing in image part.\n\t$image_part\n") unless (@images);
		return $self->log("[warn] text is missing in text part.\n\t$text_part\n") unless (@texts);
		for (my $i = 0; $i < @images or $i < @texts; $i++) {
			my $item = {};
			my ($image, $text) = ($images[$i], $texts[$i]);
			unless ($text =~ /^\s*([^<>]*)\((\d+)\)\s*$/) {
				$self->log("[warn] name or count is missing in text.\n\t$text\n") if ($i == 0);
				last;
			}
			($item->{'subject'}, $item->{'count'}) = ($1, $2);
			unless ($image =~ /(<td\b[^<>]*>)(<a\b[^<>]*>)(<img\b[^<>]*>)/) {
				$self->log("[warn] td, a or img tag is missing in image.\n\t$image\n") if ($i == 0);
				next;
			}
			my @tags = ($1, $2, $3);
			my ($td, $a, $img) = map { $self->parse_standard_tag($_) } @tags;
			$item->{'background'} = $td->{'attr'}->{'background'} or return $self->log("[warn] background is missing in tag.\n\t$tags[0]\n");
			$item->{'link'} = $a->{'attr'}->{'href'} or return $self->log("[warn] link is missing in tag.\n\t$tags[1]\n");
			$item->{'image'} = $img->{'attr'}->{'src'} or return $self->log("[warn] image is missing in tag.\n\t$tags[2]\n");
			$item->{'status'} = ($item->{'background'} and $item->{'background'} =~ /([^\/]+)$/) ? $1 : undef;
			if ($item->{'link'}) {
				$item->{'subject'}    = $self->rewrite($item->{'subject'});
				$item->{'link'}       = $self->absolute_url($item->{'link'}, $base);
				$item->{'image'}      = $self->absolute_url($item->{'image'}, $base);
				$item->{'background'} = $self->absolute_url($item->{'background'}, $base);
				$item->{'status'}     = $status_backgrounds->{$item->{'status'}};
				push(@items, $item);
			}
		}
	}
	return @items;
}

sub parse_list_community_next {
	my $self = shift;
	my ($res, $content, $url, $base) = $self->parse_parser_params(@_);
	return unless ($res and $res->is_success);
	return $self->log("[warn] Page link part is missing.\n") unless ($content =~ s/^.*\Q<!-- start: Page link -->\E(.*?)\Q<!-- end: Page link -->\E.*$/$1/s);
	return $self->log("[warn] Next page is not exists.\n")   unless ($content =~ /&nbsp;&nbsp;<a href=["']?([^"'<>\s]*)["']?.*?>(.*?)<\/a>/);
	my $subject = $2;
	my $link    = $self->absolute_url($1, $base);
	my $next    = {'link' => $link, 'subject' => $2};
	return $next;
}

sub parse_list_community_previous {
	my $self = shift;
	my ($res, $content, $url, $base) = $self->parse_parser_params(@_);
	return unless ($res and $res->is_success);
	return $self->log("[warn] Page link part is missing.\n") unless ($content =~ /\Q<!-- start: Page link -->\E(.*?)\Q<!-- end: Page link -->\E/s);
	$content = $1;
	return $self->log("[warn] Next page is not exists.\n")   unless ($content =~ /<a href=["']?([^"'<>\s]*)["']?.*?>(.*?)<\/a>&nbsp;&nbsp;/);
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
	if ($content =~ /<img src=.*? ALT=各月の日記 .*?>(.+?)<\/table>/is) {
		$content = $1;
		$content =~ s/\s+/ /gs;
		while ($content =~ s/<a HREF=['"]?(list_diary.pl\?year=(\d+)\&month=(\d+))["']?.*?>.*?<\/a>//is) {
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
		'bg_orange1-.gif' => '1時間以内',
		'bg_orange2-.gif' => '1日以内',
	};
	my @time1   = reverse((localtime(time - 3600))[0..5]);
	my @time2   = reverse((localtime(time - 3600 * 24))[0..5]);
	# get friend list part
	my $content_from = qq(\Q<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>\E);
	my $content_till = qq(\Q</table>\E);
	return $self->log("[warn] friend list part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# get friend list rows
	my @rows = ();
	push(@rows, [$1, $2]) while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<\/tr>\s*<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is);
	return $self->log("[warn] friend list has no rows.\n") unless (@rows);
	# parse each items
	foreach my $row (@rows) {
		my ($image_part, $text_part) = @{$row};
		my @images = ($image_part =~ /<td\b[^<>]*>.*?<\/td>/gi);
		my @texts  = ($text_part =~ /<td\b[^<>]*>(.*?)<\/td>/gi);
		return $self->log("[warn] image is missing in image part.\n\t$image_part\n") unless (@images);
		return $self->log("[warn] text is missing in text part.\n\t$text_part\n") unless (@texts);
		for (my $i = 0; $i < @images or $i < @texts; $i++) {
			my $item = {};
			my ($image, $text) = ($images[$i], $texts[$i]);
			$text =~ /^\s*([^<>]*)\((\d+)\)<br\b[^<>]*>/ or return $self->log("[warn] name or count is missing in text.\n\t$text\n");
			($item->{'subject'}, $item->{'count'}) = ($1, $2);
			$image =~ /(<td\b[^<>]*>)(<a\b[^<>]*>)(<img\b[^<>]*>)/ or return $self->log("[warn] td, a or img tag is missing in image.\n\t$image\n");
			my @tags = ($1, $2, $3);
			my ($td, $a, $img) = map { $self->parse_standard_tag($_) } @tags;
			$item->{'background'} = $td->{'attr'}->{'background'} or return $self->log("[warn] background is missing in tag.\n\t$tags[0]\n");
			$item->{'link'} = $a->{'attr'}->{'href'} or return $self->log("[warn] link is missing in tag.\n\t$tags[1]\n");
			$item->{'image'} = $img->{'attr'}->{'src'} or return $self->log("[warn] image is missing in tag.\n\t$tags[2]\n");
			$item->{'status'} = ($item->{'background'} and $item->{'background'} =~ /([^\/]+)$/) ? $1 : undef;
			if ($item->{'link'}) {
				$item->{'subject'}    = $self->rewrite($item->{'subject'});
				$item->{'link'}       = $self->absolute_url($item->{'link'}, $base);
				$item->{'id'}         = $2 if ($item->{'link'} =~ /(.*?)?id=(\d*)/); 
				$item->{'image'}      = $self->absolute_url($item->{'image'}, $base);
				$item->{'background'} = $self->absolute_url($item->{'background'}, $base);
				$item->{'status'}     = $status_backgrounds->{$item->{'status'}};
				push(@items, $item);
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
	# get member list part
	my $content_from = "\Q<table BORDER=0 CELLSPACING=1 CELLPADDING=2 WIDTH=560>\E";
	my $content_till = "\Q</table>\E";
	return $self->log("[warn] member list part is missing.\n") unless ($content =~ /$content_from(.+?)$content_till/s);
	$content = $1;
	# get member list rows
	my @rows = ();
	push(@rows, [$1, $2]) while ($content =~ s/<tr ALIGN=center BGCOLOR=#FFFFFF>(.*?)<\/tr>\s*<tr ALIGN=center BGCOLOR=#FFF4E0>(.*?)<\/tr>//is);
	return $self->log("[warn] no rows found in member list part.\n") unless (@rows);
	# parse each items
	foreach my $row (@rows) {
		my ($image_part, $text_part) = @{$row};
		my @images = ($image_part =~ /<td\b[^<>]*>.*?<\/td>/gi);
		my @texts  = ($text_part =~ /<td\b[^<>]*>(.*?)<\/td>/gi);
		return $self->log("[warn] image is missing in image part.\n\t$image_part\n") unless (@images);
		return $self->log("[warn] text is missing in text part.\n\t$text_part\n") unless (@texts);
		for (my $i = 0; $i < @images or $i < @texts; $i++) {
			my $item = {};
			my ($image, $text) = ($images[$i], $texts[$i]);
			unless ($text =~ /^\s*([^<>]*)\((\d+)\)\s*$/) {
				$self->log("[warn] name or count is missing in text.\n\t$text\n") if ($i == 0);
				last;
			}
			($item->{'subject'}, $item->{'count'}) = ($1, $2);
			unless ($image =~ /(<td\b[^<>]*>)(<a\b[^<>]*>)(<img\b[^<>]*>)/) {
				$self->log("[warn] td, a or img tag is missing in image.\n\t$image\n") if ($i == 0);
				next;
			}
			my @tags = ($1, $2, $3);
			my ($td, $a, $img) = map { $self->parse_standard_tag($_) } @tags;
			$item->{'background'} = $td->{'attr'}->{'background'} or return $self->log("[warn] background is missing in tag.\n\t$tags[0]\n");
			$item->{'link'} = $a->{'attr'}->{'href'} or return $self->log("[warn] link is missing in tag.\n\t$tags[1]\n");
			$item->{'image'} = $img->{'attr'}->{'src'} or return $self->log("[warn] image is missing in tag.\n\t$tags[2]\n");
			$item->{'status'} = ($item->{'background'} and $item->{'background'} =~ /([^\/]+)$/) ? $1 : undef;
			if ($item->{'link'}) {
				$item->{'subject'}    = $self->rewrite($item->{'subject'});
				$item->{'link'}       = $self->absolute_url($item->{'link'}, $base);
				$item->{'image'}      = $self->absolute_url($item->{'image'}, $base);
				$item->{'background'} = $self->absolute_url($item->{'background'}, $base);
				$item->{'id'}         = $1 if ($item->{'link'} =~ /\bid=(\d+)/); 
				push(@items, $item);
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
	# get request list part
	my $content_from = '<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>';
	my $content_till = "<[^<>]*\Qhttp://img.mixi.jp/img/q_brown3.gif\E[^<>]*>";
	return $self->log("[warn] Request list part is missing.\n") unless ($content =~ /$content_from(.+?)$content_till/s);
	$content = $1;
	# get requests
	my @records = ($content =~ /<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=550>(.*?)<\/table>/isg);
	return $self->log("[info] No request found.\n") if (not @records);
	# parse requests
	foreach my $record (@records) {
		my $record = $1;
		my @lines = ($record =~ /<tr.*?>(.*?)<\/tr>/gis);
		my $item = {};
		# parse record
		($item->{'link'}, $item->{'image'})  = ($1, $2) if ($lines[0] =~ /<td WIDTH=90 .*?><a href="([^"]*show_friend.pl\?id=\d+)"><img SRC="([^"]*)".*?>/is);
		($item->{'subject'}, $item->{'gender'}) = ($1, $2) if ($lines[0] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?) \((.*?)\)<\/td>/is);
		$item->{'description'} = $1 if ($lines[1] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
		$item->{'message'} = $1 if ($lines[2] =~ /<td COLSPAN=2 BGCOLOR=#FFFFFF>(.*?)<\/td>/is);
		$item->{'time'} = $1 if ($lines[3] =~ /<td BGCOLOR=#FFFFFF WIDTH=140>(.*?)<\/td>/is);
		while ($lines[3] =~ s/<a href="(.*?)"><img src=["']?(.*?)['"]? ALT=["']?(.*?)['"]? [^<>]*?><\/a>//) {
			my $button = { 'link' => $1, 'image' => $2, 'title' => $3 };
			map { $button->{$_} = $self->absolute_url($button->{$_}, $base) } qw(link image);
			map { $button->{$_} = $self->rewrite($button->{$_}, $base) }      qw(title);
			$item->{'button'} = [] unless ($item->{'button'});
			push(@{$item->{'button'}}, $button);
		}
		# format
		map { $item->{$_} = $self->absolute_url($item->{$_}, $base) } qw(link image);
		map { $item->{$_} = $self->rewrite($item->{$_}, $base) }      qw(subject description message gender);
		$item->{'time'} = $self->convert_login_time($item->{'time'}) if ($item->{'time'});
		push(@items, $item) if ($item->{'subject'} and $item->{'link'});
	}
	@items = sort { $b->{'time'} cmp $a->{'time'} } @items;
	return @items;
}

sub parse_new_album        { &parse_standard_history(@_); }
sub parse_new_bbs          { &parse_standard_history(@_); }
sub parse_new_bbs_next     { &parse_standard_history_next(@_); }
sub parse_new_bbs_previous { &parse_standard_history_previous(@_); }
sub parse_new_comment      { &parse_standard_history(@_); }
sub parse_new_friend_diary { &parse_standard_history(@_); }
sub parse_new_friend_diary_next { &parse_standard_history_next(@_); }
sub parse_new_friend_diary_previous { &parse_standard_history_previous(@_); }
sub parse_new_review       { &parse_standard_history(@_); }

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
	my $session = $self->session;
	return ($session and $session =~ /^(\d+)_/) ? $1 : 0;
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
	# get calendar part
	my $content_from = qq(\Q<table width="670" border="0" cellspacing="1" cellpadding="3">\E);
	my $content_till = qq(\Q</table>\E);
	return $self->log("[warn] calendar part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse main menu items
	my @days = ();
	$content =~ s/<tr align=center bgcolor=#fff1c4>.*?<\/tr>//is;
	push(@days, [$1, $2]) while ($content =~ s/<td height=65 [^<>]*><font color=#996600>\s*(\d+)\s*<\/font>(.*?)<\/td>//is);
	return $self->log("[warn] no day found in calendar.\n") unless (@days);
	# parse each days
	foreach my $day (@days) {
		my ($date, $text) = @{$day};
		$date = sprintf('%04d/%02d/%02d', $term->{'year'}, $term->{'month'}, $date);
		if ($text =~ s/<img src=(.*?) width=23 height=16 align=absmiddle \/>(.*?)<\/font><\/font>//i) {
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
			if ($event =~ /<img src=(.*?) width=16 height=16 align=middle \/><a href=(.*?)>(.*?)<\/a>/i) {
				$item = { 'subject' => $1, 'link' => $2, 'name' => $3, 'time' => $date, 'icon' => $1};
			} elsif ($event =~ /<a href=".*?" onClick="MM_openBrWindow\('(view_schedule.pl\?id=\d+)'.*?\)"><img src=(.*?) .*?>(.*?)<\/a>/i) {
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
	return @items;
}

sub parse_show_calendar_term {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	return unless ($content =~ /<a href="show_calendar.pl\?year=(\d+)&month=(\d+)&pref_id=\d+">[^&]*?<\/a>/);
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

sub parse_show_intro {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /からの紹介文(.+?)<!--フッタ-->/s) {
		$content = $1;
		while ($content =~ s/<tr bgcolor=#FFFFFF>.*?<a href="(.+?)"><img src="(.+?)".*?\n(.+?)<\/td>.*?<td WIDTH=480>\n(.*?)\n(.*?)<\/td>//is) {
			my ($link, $img, $name, $rel, $desc) = ($1, $2, $3, $4, $5);
			$rel =~ s/関係：(.+?)<br>/$1/;
			my $intro = ($desc =~ /edit_intro.pl\?id=.+?\&type=edit/) ? "1" : "0";
			my $delete = ($desc =~ s/<a href="delete_intro.pl\?id=(\d+)">削除<\/a>//s) ? "1" : "0";
			$name = $self->rewrite($name);
			$rel  = $self->rewrite($rel);
			$desc = $self->rewrite($desc);
			$desc =~ s/この友人を紹介する//;
			$desc =~ s/[\r\n]+//ig;
			$link = $self->absolute_url($link, $base);
			my $item = {'link' => $link, 'name' => $name, 'image' => $img, 'relation' => $rel, 'description' => $desc, 'introduction' => $intro, 'detele' => $delete};
			push(@items, $item);
		}
	}
	return @items;
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
	# get log part
	my $content_from = qq(\Q<ul class="log" style="margin: 0; padding: 0;">\E);
	my $content_till = qq(\Q</ul>\E);
	return $self->log("[warn] log part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse main menu items
	my @lines = ($content =~ /<li\b[^<>]*>(.*?)<\/li>/gs);
	return $self->log("[warn] no log found in log part.\n") unless (@lines);
	# parse each items
	foreach my $line (@lines) {
		$line =~ /${re_date} (<a\b[^<>]*>)(.*)<\/a>/ or return $self->log("[warn] a tag, date or name in not found in '$line'.\n");
		my $time = sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $4, $5);
		my $a    = $self->parse_standard_tag($6);
		my $name = $self->rewrite($7);
		my $link = $self->absolute_url($a->{'attr'}->{'href'}, $base);
		push(@items, {'time' => $time, 'name' => $name, 'link' => $link});
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

sub parse_view_album {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /概要ここから(.+?)<!--フッタ-->/s) {
		my $img = $1 if ($content =~ /width=250><img ALT="" SRC="(.*?)" VSPACE=4><\/td>/);
		my $name = $1 if ($content =~ /<b>(.*?)さんのフォトアルバム/);
		my $subj = $1 if ($content =~ /タイトル.*?<b>(.*?)<\/b>/s);
		my $desc = $1 if ($content =~ /説明.*?CLASS=h120>(.*?)<\/td>/s);
		my $level = $1 if ($content =~ /公開レベル.*?<td bgcolor=#FFFFFF>(.*?)<br>/s);
		my $time = sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $5, $5) if ($content =~ /作成日時.*?<td bgcolor=#FFFFFF>(\d{4})年(\d{2})月(\d{2})日&nbsp;(\d{2}):(\d{2})<\/td>/s);
		my $comm = $1 if ($content =~ />コメント\((\d+)\)/);
		my $number = $1 if ($content =~ /写真一覧.*?\&nbsp;(\d+)枚/);
		$name = $self->rewrite($name);
		$subj = $self->rewrite($subj);
		$desc = $self->rewrite($desc);
		my $item = { 'image' => $self->absolute_url($img, $base), 'name' => $name, 'subject' => $subj, 'description' => $desc, 'level' => $level, 'time' => $time, 'comment_number' => $comm, 'photo_number' => $number};
		push(@items, $item);
	}
	return @items;
}

sub parse_view_album_comment {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	# get comment part
	my $content_from = "\Q<!-- コメント : start -->\E";
	my $content_till = "\Q<!-- コメント : end -->\E";
	return $self->log("[warn] Comment list part is missing.\n") unless ($content =~ /$content_from(.+?)$content_till/s);
	$content = $1;
	# parse comments
	my @items   = ();
	while ($content =~ s/<td [^<>]*rowspan="2"[^<>]*>\n(\d{4})年(\d{2})月(\d{2})日<br>(\d{2}):(\d{2})<br>\n<\/td>.*?<a href="(.+?)">(.+?)<\/a>.*?<td class="h120">(.*?)<\/td>//s) {
		my ($time, $link, $name, $desc) = ((sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $4, $5)), $6, $7, $8);
		my $item = { 'time' => $time, 'link' => $self->absolute_url($link, $base), 'name' => $self->rewrite($name), 'description' => $self->rewrite($desc)};
		push(@items, $item);
	}
	return @items;
}

sub parse_view_album_photo {
	my $self    = shift;
	my $res     = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base    = $res->base->as_string;
	my $content = $res->content;
	my @items   = ();
	if ($content =~ /写真一覧ここから(.*?)写真一覧ここまで/s) {
		$content = $1;
		while ($content =~ s/<td.*?<img alt="(.+?)" src="(.+?)".*?<a href="(.+?)">(.+?)<\/a><\/td>//) {
			my ($alt, $thumb, $link, $subj) = ($1, $2, $3, $4);
			my $item = { 'description' => $alt, 'thumb_link' => $self->absolute_url($thumb, $base), 'link' => $self->absolute_url($link, $base), 'subject' => $self->rewrite($subj)};
			push(@items, $item);
		}
	}
	return @items;
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
	my $re_c_desc = '<td class="h120">(.+?)\n</td>';
	my $re_link   = '<a href="?(.+?)"?>(.*?)<\/a>';
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
	my $re_c_date = '<td rowspan="2" align="center" width="95" bgcolor="#f2ddb7" nowrap>\n(\d{4})年(\d{2})月(\d{2})日<br>(\d{1,2}):(\d{2})';
	my $re_link   = '<a href="?(.+?)"?>(.+?)<\/a>';
	if ($content =~ s/<tr VALIGN=top>.*?${re_date}.*?${re_subj}(.*?)${re_desc}(.+)//is) {
		my ($time, $subj, $imgs, $desc, $comm) = (sprintf('%04d/%02d/%02d %02d:%02d', $1,$2,$3,$4,$5), $6, $7, $8, $9);
		my $level = { 'description' => $self->rewrite($2), 'link' => $self->absolute_url($1, $base) } if ($content =~ /<img src="([^"]+)" alt="([^"]+)" height="\d+" hspace="\d+" width="\d+">/);
		($desc, $subj) = map { s/[\r\n]+//g; s/<br>/\n/g; $_ = $self->rewrite($_); } ($desc, $subj);
		my $item = { 'time' => $time, 'description' => $desc, 'subject' => $subj, 'link' => $res->request->uri->as_string, 'images' => [], 'comments' => [], 'level' => $level };
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

sub parse_view_event {
	my $self = shift;
	my ($res, $content, $url, $base) = $self->parse_parser_params(@_);
	return unless ($res and $res->is_success);
	my @items   = ();
	# get event, pages, comments part
	my $event_from       = "\Q<!--///// トピックここから /////-->\E";
	my $content_event    = ($content =~ /$event_from(.*?)\Q<!-- TOPIC: end -->\E/s)                   ? $1 : return $self->log("[warn] event part is missing.\n");
	my $content_pages    = ($content =~ /\Q<!-- COMMENT: start -->\E(.*?)\Q<!-- start : Loop -->\E/s) ? $1 : '';
	my $content_comments = ($content =~ /\Q<!-- start : Loop -->\E(.*?)\Q<!-- end : Loop -->\E/s)     ? $1 : '';
	# make regex for table parsing
	my $attr = qr/\s+(?:"[^""]*"|'[^'']*'|[^<>]+)?/;
	my ($table, $tr, $td) = (qr/table(?:$attr)*/, qr/tr(?:$attr)*/, qr/td(?:$attr)*/);
	my $char = qr/(?!<\/?(?:table|th|tr|td)(?:$attr)*>)[\s\S]/;
	my $str  = qr/(?:$char)*/;
	my $s    = qr/(?:\s+|\Q&nbsp;\E)*/;
	# parse event
	my $item   = {};
	my $time   = sprintf('%04d/%02d/%02d %02d:%02d', $2, $3, $4, $5, $6) if ($content_event =~ /(<$td>$s(\d{4})年(\d{2})月(\d{2})日$str(\d{1,2}):(\d{2})<\/$td>)/is);
	my @images = ($1, $2, $3) if ($content_event =~ /$1$s<$td>$s<$table>$s<$tr>$s<$td>($str)<\/$td>(?:$s<$td>($str)<\/$td>(?:$s<$td>($str)<\/$td>)?)?$s<\/$tr>$s<\/$table>$s<\/$td>$s<\/$tr>/is);
	my $subj   = $1 if ($content_event =~ /<$td>$s\Qタイトル\E$s<\/$td>$s<$td>$s($str)<\/$td>/is);
	return $self->log("[warn] Can't parse event time.\n")  unless(defined($time));
	return $self->log("[warn] Can't parse event title.\n") unless(defined($subj));
	my $name   = $1 if ($content_event =~ /<$td>$s\Q企画者\E$s<\/$td>$s<$td>$s($str)<\/$td>/is);
	my $date   = $1 if ($content_event =~ /<$td>$s\Q開催日時\E$s<\/$td>$s<$td>$s($str)<\/$td>/is);
	my $loca   = $1 if ($content_event =~ /<$td>$s\Q開催場所\E$s<\/$td>$s<$td>$s($str)<\/$td>/is);
	my $comm   = $1 if ($content_event =~ /<$td>$s\Q関連コミュニティ\E$s<\/$td>$s<$td>$s($str)<\/$td>/is);
	my $desc   = $1 if ($content_event =~ /<$td>$s\Q詳細\E$s<\/$td>$s<$td><$table>$s<$tr>$s<$td>($str)<\/$td>$s<\/$tr>$s<\/$table>$s<\/$td>/is);
	my $limit  = $1 if ($content_event =~ /<$td>$s\Q募集期限\E$s<\/$td>$s<$td>$s($str)<\/$td>/is);
	my ($count, $list) = ($1, $2) if ($content_event =~ /<$td>$s\Q参加者\E$s<\/$td>$s<$td>$s<$table>$s<$tr>$s<$td>$s($str)<\/$td>$s<$td>$s($str)<\/$td>/is);
	my $join  = $1 if ($content_event =~ /<form(?:$attr)*>$s<$tr>$s<$td>$s<input(?:$attr)*VALUE="([^""]*)"(?:$attr)*>$s<\/$td>$s<\/$tr>$s<\/form>/is);
	$join = ($join eq '　イベントに参加する　') ? 1 : ($join eq "　参加をキャンセルする　") ? 2 : 0;
	($comm, my $comm_link) = ($comm =~ /<a(?:$attr)*href=["']?([^"'<> ]*)["'](?:$attr)*>(.*?)<\/a>/is) ? ($2, $self->absolute_url($1, $base)) : (undef, undef);
	($list, my $list_link) = ($list =~ /<a(?:$attr)*href=["']?([^"'<> ]*)["'](?:$attr)*>(.*?)<\/a>/is) ? ($2, $self->absolute_url($1, $base)) : (undef, undef);
	($name, my $name_link) = ($name =~ /<a(?:$attr)*href=["']?([^"'<> ]*)["'](?:$attr)*>(.*?)<\/a>/is) ? ($2, $self->absolute_url($1, $base)) : (undef, undef);
	($subj, $desc, $date, $loca) = map { s/[\r\n]+//g; s/<br>/\n/g; $_ = $self->rewrite($_); } ($subj, $desc, $date, $loca);
	$item = {
		'time'   => $time, 'description' => $desc, 'subject'  => $subj,  'link' => $url, 'name' => $name, 'name_link' => $name_link,
		'date'   => $date, 'location'    => $loca, 'deadline' => $limit, 'join' => $join,
		'images' => [],    'comments'    => [],    'pages'    => [],
		'list'      => { 'subject' => $list, 'link' => $list_link, 'count' => $count },
		'community' => { 'name'    => $comm, 'link' => $comm_link },
	};
	foreach my $image (@images) {
		next unless ($image and $image =~ /<a(?:$attr)*onClick="MM_openBrWindow\('([^']*?)'.*?\)[^""]*"(?:$attr)*>$s<img(?:$attr)*src=["']?([^"'\s]*)["']?(?:$attr)*>/);
		push(@{$item->{'images'}}, {'link' => $self->absolute_url($1, $base), 'thumb_link' => $self->absolute_url($2, $base)});
	}
	# parse pages
	if ($content_pages and $content_pages =~ /(.*\Q全てを表示\E.*)\Q&nbsp;&nbsp;[\E(.*?)\Q]&nbsp;&nbsp;\E(.*\Q最新の10件を表示\E.*)/) {
		my @pages = ($1, $2, $3);
		splice(@pages, 1, 1, ($pages[1] =~ /(<a(?:$attr)*>.*?<\/a>|\d+)/gi));
		foreach my $page (@pages) {
			if ($page =~ /<a(?:$attr)*href=["']?([^"'<>]*)["']?(?:$attr)*>(.*?)<\/a>/) {
				push(@{$item->{'pages'}}, { 'current' => 0, 'link' => $self->absolute_url($1, $base), 'subject' => $2});
			} else {
				push(@{$item->{'pages'}}, { 'current' => 1, 'link' => $url, 'subject' => $page});
			}
		}
	}
	# parse comments
	if ($content_comments) {
		my @comments = split(/<td(?:$attr)*rowspan=2(?:$attr)*>/i, $content_comments);
		foreach my $comment (@comments) {
			next unless ($comment =~ /
				^$s(\d{4})年(\d{2})月(\d{2})日$str(\d{1,2}):(\d{2})$str<\/$td>$s
				<$td>$str<b>$s(\d+)$s<\/b>$s:($str)<\/$td>$s<\/$tr>
			/isx);
			my $time = sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $4, $5);
			my ($subj, $name) = ($6, $7);
			my @images = ($1, $2, $3) if ($comment =~ s/<$table>$s<$tr>$s<$td>($str<img(?:$attr)*>$str)<\/$td>(?:$s<$td>($str<img(?:$attr)*>$str)<\/$td>)?(?:$s<$td>($str<img(?:$attr)*>$str)<\/$td>)?$s<\/tr><\/table>//is);
			my $desc = $self->rewrite($1) if ($comment =~ /<$tr>$s<$td>$s<$table>$s<$tr>$s<$td>($str)<\/$td>$s<\/$tr>$s<\/$table>$s<\/$td>$s<\/$tr>/is);
			@images = grep { $_ } map {
				($_ and /<a(?:$attr)*onClick="MM_openBrWindow\('([^']*?)'.*?\)[^""]*"(?:$attr)*>$s<img(?:$attr)*src=["']?([^"'\s]*)["']?.*?>/)
				? {'link' => $self->absolute_url($1, $base), 'thumb_link' => $self->absolute_url($2, $base)} : undef
			} @images;
			($name, my $link) = ($name =~ /<a(?:$attr)*href=["']?([^"'<> ]*)["'](?:$attr)*>(.*?)<\/a>/is) ? ($2, $self->absolute_url($1, $base)) : (undef, undef);
			push(@{$item->{'comments'}}, {'subject' => $subj, 'name' => $name, 'link' => $link, 'time' => $time, 'description' => $desc, 'images' => [@images]});
		}
	}
	push(@items, $item);
	return @items;
}

sub parse_view_message {
	my $self      = shift;
	my $res       = (@_) ? shift : $self->response();
	return unless ($res and $res->is_success);
	my $base      = $res->request->uri->as_string;
	my $content   = $res->content;
	# make regex for table parsing
	my $attr = qr/\s+(?:"[^""]*"|'[^'']*'|[^<>]+)?/;
	my ($table, $tr, $td) = (qr/table(?:$attr)*/, qr/tr(?:$attr)*/, qr/td(?:$attr)*/);
	my $char = qr/(?!<\/?(?:table|th|tr|td)(?:$attr)*>)[\s\S]/;
	my $str  = qr/(?:$char)*/;
	my $s    = qr/(?:\s+|\Q&nbsp;\E)*/;
	# get request list part
	my $content_from = "\Q<b>メッセージの詳細</b>\E";
	my $content_till = "<[^<>]*\Qhttp://img.mixi.jp/img/q_brown3.gif\E[^<>]*>";
	return $self->log("[warn] Detail part is missing.\n") unless ($content =~ /$content_from(.+?)$content_till/s);
	$content = $1;
	# parse message
	my $item  = {};
	my $label_time = "(?:\Q日　付\E|\Q日&nbsp;付\E)";
	my $label_name = "(?:\Q差出人\E|\Q宛&nbsp;先\E)";
	my $label_subj = "(?:\Q件　名\E|\Q件&nbsp;名\E)";
	my $time  = sprintf('%04d/%02d/%02d %02d:%02d', $1, $2, $3, $4, $5) if ($content =~ /<$td>$s<font(?:$attr)*>$label_time<\/font>$s:$s(\d{4})年(\d{2})月(\d{2})日$s(\d{2}):(\d{2})<\/td>/is);
	my $subj  = $self->rewrite($1) if ($content =~ /<$td>$s<font(?:$attr)*>$label_subj<\/font>$s:$s($str)<\/td>/is);
	my $desc  = $self->rewrite($1) if ($content =~ /<td(?:$attr)*CLASS=h120(?:$attr)*>$s($str)<\/td>/is);
	my $image = $self->absolute_url($1, $base) if ($content =~ /<$td><a(?:$attr)*><img(?:$attr)*src=["']?([^"'\s<>]+)["'](?:$attr)*><\/a><\/td>/is);
	my $name  = $1 if ($content =~ /<$td>$s<font(?:$attr)*>$label_name<\/font>$s:$s($str)<\/td>/is);
	($name, my $link) = ($name =~ /<a(?:$attr)*href=["']?([^"'<> ]*)["'](?:$attr)*>(.*?)(?:<\/a>)?$/is) ? ($self->rewrite($2), $self->absolute_url($1, $base)) : ($self->rewrite($name), undef);
	$item = { 'subject' => $subj, 'time' => $time, 'name' => $name, 'link' => $link, 'image' => $image, 'description' => $desc };
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

sub get_information           { my $self = shift; return $self->get_standard_data('parse_information',           'home.pl', @_); }
sub get_home_new_album        { my $self = shift; return $self->get_standard_data('parse_home_new_album',        'home.pl', @_); }
sub get_home_new_bbs          { my $self = shift; return $self->get_standard_data('parse_home_new_bbs',          'home.pl', @_); }
sub get_home_new_comment      { my $self = shift; return $self->get_standard_data('parse_home_new_comment',      'home.pl', @_); }
sub get_home_new_friend_diary { my $self = shift; return $self->get_standard_data('parse_home_new_friend_diary', 'home.pl', @_); }
sub get_home_new_review       { my $self = shift; return $self->get_standard_data('parse_home_new_review',       'home.pl', @_); }

sub get_ajax_new_diary {
	my $self = shift;
	my $url     = 'ajax_new_diary.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'friend_id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'friend_id'}) and length($param{'friend_id'}) and $url !~ /[\?\&]friend_id=/) {
		$url .= ($url =~ /\?/) ? "&friend_id=$param{'friend_id'}" : "?friend_id=$param{'friend_id'}";
	}
	return $self->get_standard_data('parse_ajax_new_diary', qr/ajax_new_diary\.pl/, $url, $refresh);
}

sub get_community_id {
	my $self = shift;
	return $self->get_standard_data('parse_community_id', qr/view_community\.pl/, @_);
}

sub get_edit_member {
	my $self    = shift;
	my $url     = 'edit_member.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if ($url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}"     : "?id=$param{'id'}"   if (defined($param{'id'})   and length($param{'id'}));
		$url .= ($url =~ /\?/) ? "&page=$param{'page'}" : "?id=$param{'page'}" if (defined($param{'page'}) and length($param{'page'}));
	}
	return $self->get_standard_data('parse_edit_member', qr/edit_member\.pl/, $url, $refresh);
}

sub get_edit_member_pages {
	my $self    = shift;
	my $url     = 'edit_member.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if ($url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}"     : "?id=$param{'id'}"   if (defined($param{'id'})   and length($param{'id'}));
		$url .= ($url =~ /\?/) ? "&page=$param{'page'}" : "?id=$param{'page'}" if (defined($param{'page'}) and length($param{'page'}));
	}
	return $self->get_standard_data('parse_edit_member_pages', qr/edit_member\.pl/, $url, $refresh);
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
	$self->login unless ($self->is_logined);
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
	return $self->parse_show_calendar();
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

sub get_show_intro {
	my $self = shift;
	my $url  = 'show_intro.pl';
	$url     = shift if (@_ and $_[0] ne 'refresh');
	$self->set_response($url, @_) or return;
	return $self->parse_show_intro();
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

sub get_view_album {
	my $self    = shift;
	my $url     = 'view_album.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	return $self->get_standard_data('parse_view_album', qr/view_album\.pl/, $url, $refresh);
}

sub get_view_album_comment {
	my $self = shift;
	my $url     = 'view_album.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}&mode=comment";
	}
	return $self->get_standard_data('parse_view_album_comment', qr/view_album\.pl/, $url, $refresh);
}

sub get_view_album_photo {
	my $self = shift;
	my $url     = 'view_album.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	return $self->get_standard_data('parse_view_album_photo', qr/view_album\.pl/, $url, $refresh);
}

sub get_view_bbs {
	my $self = shift;
	my $url  = shift or return;
	$self->set_response($url, @_) or return undef;
	return $self->parse_view_bbs();
}

sub get_view_community {
	my $self = shift;
	my $url     = 'view_community.pl';
	$url        = shift if (@_ and $_[0] ne 'refresh' and $_[0] ne 'id');
	my $refresh = shift if (@_ and $_[0] eq 'refresh');
	my %param   = @_;
	if (defined($param{'id'}) and length($param{'id'}) and $url !~ /[\?\&]id=/) {
		$url .= ($url =~ /\?/) ? "&id=$param{'id'}" : "?id=$param{'id'}";
	}
	return $self->get_standard_data('parse_view_community', qr/view_community\.pl/, $url, $refresh);
}

sub get_view_diary {
	my $self = shift;
	my $url  = shift or return;
	$self->set_response($url, @_) or return undef;
	return $self->parse_view_diary();
}

sub get_view_event {
	my $self = shift;
	my $url  = shift or return;
	$self->set_response($url, @_) or return undef;
	return $self->parse_view_event();
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
	my $self = shift;
	my %form = @_;
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
	$url =~ s/view_diary.pl\?(?:.*&)?(id=\d+).*?$/edit_diary.pl?$1/;
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

sub parse_parser_params {
	my $self     = shift;
	my @params   = @_;
	my $response = undef;
	my $content  = undef;
	foreach my $param (@params) {
		if (UNIVERSAL::isa($param, 'HTTP::Response')) {
			$response = $param;
		} elsif (not ref($param)) { # File or Content
			if ($param !~ /\t\r\n/ and -f $param) {
				if (open(IN, $param)) { # Slurp file
					local $/;
					$content = <IN>;
					close(IN);
				}
			} else {
				$content = $param;
			}
		}
	}
	$response = ($content or not $self->response) ? HTTP::Response->new(200) : $self->response unless ($response);
	$response->content($content)   if ($content);
	$content  = $response->content if (not $content);
	my $base = eval { $response->base->as_string } || 'http://mixi.jp/';
	my $url  = eval { $response->request->uri->as_string };
	return ($response, $content, $url, $base);
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
	my $logger = $self->{'mixi'}->{'log'} or return;
	if    (ref($logger) eq 'CODE')                         { &{$logger}($self, @_); }
	elsif (ref($logger) eq '' and $logger =~ /^[1-9]\d*$/) { $self->callback_log(@_); }
	return;
}

sub callback_log {
	my $self  = shift;
	my @logs  = @_;
	my $code  = $self->{'mixi'}->{'logcode'};
	if (defined($code) and not defined($self->{'mixi'}->{'ref_convert'})) {
		$self->{'mixi'}->{'ref_convert'} = 0;
		if ($code ne 'euc') {
			$self->log("[info] Initialize Jcode for logging with '$code'.\n");
			eval "use Jcode";
			if    ($@)                    { $self->log("[warn] Can't use Jcode module.\n"); }
			elsif (not Jcode->can($code)) { $self->log("[warn] Jcode can't handle '$code'.\n"); }
			else  { $self->{'mixi'}->{'ref_convert'} = Jcode->can('convert'); }
		}
	}
	my $jconv = $self->{'mixi'}->{'ref_convert'};
	my $level = (ref($self->{'mixi'}->{'log'}) eq '') ? $self->{'mixi'}->{'log'} : 1;
	my $error = 0;
	foreach my $log (@logs) {
		my $log_level = 0;
		if    ($log !~ /^(\s|\[.*?\])/) { $log_level = 1; }
		elsif ($log =~ /^\[error\]/)    { $log_level = 1; $error = 1; }
		elsif ($log =~ /^\[usage\]/)    { $log_level = 2; }
		elsif ($log =~ /^\[warn\]/)     { $log_level = 2; }
		elsif ($log =~ /^\[info\]/)     { $log_level = 3; }
		elsif ($log =~ /^\s/)           { $log_level = 4; }
		else                            { $log_level = 5; }
		if ($log_level and $log_level <= $level) { 
			$log = &{$jconv}($log, $code, 'euc') if ($jconv);
			print $log;
		}
	}
	$self->abort if ($error);
	return;
}

sub dumper_log {
	my $self = shift;
	my @logs = @_;
	if (not defined($self->{'mixi'}->{'dumper'})) {
		$self->log("Data::Dumperを初期化します。\n");
		eval "use Data::Dumper";
		if ($@) {
			$self->{'mixi'}->{'dumper'} = 0;
			$self->log("[warn] Data::Dumperは使用できません : $@\n");
		} else {
			$self->{'mixi'}->{'dumper'} = Data::Dumper->new([]);
			eval { $self->{'mixi'}->{'dumper'}->Indent(1); $self->{'mixi'}->{'dumper'}->Sortkeys(1); };
		}
	}
	if ($self->{'mixi'}->{'dumper'}) {
		my $log = $self->{'mixi'}->{'dumper'}->Reset->Values([@logs])->Dump;
		$log =~ s/(?:\x0D\x0A?|\x0A)/\n  /gs;
		$log =~ s/\s*$/\n/s;
		return $self->log("  $log");
	} else {
		@logs = map { s/\s*$/\n/s; s/(?:\x0D\x0A?|\x0A)/\n  /gs; $_ = "  [dumper] $_"; } @logs;
		return $self->log(@logs);
	}
}

sub abort {
	my $self = shift;
	return &{$self->{'mixi'}->{'abort'}}($self, @_);
}

sub callback_abort {
	die @_;
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
	$str =~ s/\x0d\x0a?|\x0a/\n/g;
	$str =~ s/\s+$//s;
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
	return $str;
}

sub remove_tag {
	my $self = shift;
	my $html = shift;
	my $text = '';
	my $indent = '';
	my $blockquote = 0;
	my $re_standard_tag = q{[^"'<>]*(?:"[^"]*"[^"'<>]*|'[^']*'[^"'<>]*)*(?:>|(?=<)|$(?!\n))};
	my $re_comment_tag = '<!(?:--[^-]*-(?:[^-]+-)*?-(?:[^>-]*(?:-[^>-]+)*?)??)*(?:>|$(?!\n)|--.*$)';
	my $re_html_tag = qq{$re_comment_tag|<$re_standard_tag};
	while ($html =~ /([^<]*)($re_html_tag)?/gso) {
		last if ($1 eq '' and $2 eq '');
		my ($tmp_text, $tmp_tag) = ($1, $2);
		$tmp_text =~ s/\n/\n$indent/go if ($indent);
		$text .= $tmp_text;
		if ($tmp_tag =~ /^<(\/?)blockquote[ >]/i) {
			$blockquote += ($1) ? -1 : 1;
			$indent = ($blockquote > 0) ? '>' x $blockquote . ' ' : '';
			$text .= ($1) ? "\n\n" : "\n\n$indent";
		}
	}
	return $text;
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
	my $re_link = '<a [^<>]*href="?([^<> ]*?)"?(?: [^<>]*)?>(.*?)<\/a>';
	my $re_name = '\(([^<>]*)\)';
	my @today = reverse((localtime)[3..5]);
	$today[0] += 1900;
	$today[1] += 1;
	# get standard history part
	my $content_from = qq(\Q<table BORDER=0 CELLSPACING=1 CELLPADDING=4 WIDTH=630>\E);
	my $content_till = qq(\Q<\/table>\E);
	return $self->log("[warn] standard history part is missing.\n") unless ($content =~ /$content_from(.*?)$content_till/s);
	$content = $1;
	# parse standard history part
	foreach my $row ($content =~ /<tr bgcolor=#FFFFFF>(.*?)<\/tr>/isg) {
		$row =~ s/\s*[\r\n]\s*//gs;
		my @cols = ($row =~ /<td[^<>]*>(.*?)<\/td>/gs);
		my $item = {};
		next unless ($cols[0] =~ s/$re_date//);
		my @date           = ($1, $2, $3, $4, $5);
		next unless ($cols[1] =~ /${re_link}\s*$re_name/);
		$item->{'link'}    = $self->absolute_url($1, $base);
		$item->{'subject'} = (defined($2) and length($2)) ? $self->rewrite($2) : '(削除)';
		$item->{'name'}    = $self->rewrite($3);
		$date[0]           = ($date[1] > $today[1]) ? $today[0] - 1 : $today[0] if (not defined($date[0]));
		$item->{'time'}    = sprintf('%04d/%02d/%02d %02d:%02d', @date);
		map { $item->{$_} =~ s/^\s+|\s+$//gs } (keys(%{$item}));
		if ($cols[1] =~ /(<a [^>]*>)\s*(<img [^>]*>)\s*<\/a>/is) {
			my $image = {};
			my @tags = ($1, $2);
			if ($_ = $self->parse_standard_tag($tags[0]) and $_->{'attr'}->{'href'} or $_->{'attr'}->{'onclick'}) {
				$_ = ($_->{'attr'}->{'onclick'}) ? $_->{'attr'}->{'onclick'} : $_->{'attr'}->{'href'};
				$_ = $1 if ($_ =~ /MM_openBrWindow\('(.*?)'/);
				$item->{'image'}->{'link'} = $self->absolute_url($_, $base);
			}
			$item->{'image'}->{'src'}  = $self->absolute_url($_, $base) if ($_ = $self->parse_standard_tag($tags[1]) and $_ = $_->{'attr'}->{'src'});
		}
		push(@items, $item);
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

sub parse_standard_tag {
	my $self = shift;
	my $str = shift;
	return undef unless ($str =~ s/^\s*<(.*)>\s*$/$1/s);
	return undef if ($str =~ /^\!--/);
	my $re_word  = q{[^"'<>\s=]+};                             #"]}
	my $re_quote = q{(?:"[^"]*"|'[^']*')};                     #")}
	my $re_pair  = qq{$re_word\\s*=\\s*(?:$re_quote|$re_word\\((?:[^)]*|$re_quote)*\\)|[^"'<>\\s]+)?};
	my $re_parse = qq{$re_pair|$re_word|$re_quote};
	my @parsed = ($str =~ /$re_parse/gs);
	my $tag = lc(shift(@parsed));
	@parsed = map { /^($re_word)\s*=\s*(.*)$/ ? (lc($1) => $2) : (lc($_) => '') } @parsed;
	@parsed = map { /^\s*=\s*$/ ? '=' :/^"(.*)"$/ ? $1 : /^'(.*)'$/ ? $1 : $_ } @parsed;
	return { 'tag' => $tag, , 'attr' => {@parsed} };
}

sub parse_standard_anchor {
	my $self   = shift;
	my $str    = shift;
	my $parsed = $self->parse_standard_tag($str);
	my $link   = undef;
	return undef unless ($parsed);
	if ($parsed->{'attr'}->{'onclick'}) {
		if    ($parsed->{'attr'}->{'onclick'} =~ /MM_openBrWindow\(("[^""]*"|'[^'']*'|[^\s\)]*)/)             { $link = $1; }
		elsif ($parsed->{'attr'}->{'onclick'} =~ /window.opener.location.href=("[^""]*"|'[^'']*'|[^\s\)]*)/i) { $link = $1; }
		1 if (defined($link) and ($link =~ s/^"(.*?)"/$1/ or $link =~ s/^'(.*?)'/$1/));
	}
	$link = $parsed->{'attr'}->{'href'} if (not defined($link));
	return $link;
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
	my @fields   = qw(submit diary_title diary_body photo1 photo2 photo3 orig_size packed post_key id news_id);
	my @required = qw(submit diary_title diary_body id);
	my @files    = qw(photo1 photo2 photo3);
	my %label    = ('diary_title' => '日記のタイトル', 'diary_body' => '日記の本文', 'photo1' => '写真1', 'photo2' => '写真2', 'photo3' => '写真3', orig_size => '圧縮指定', packed => '送信データ', 'post_key' => '送信キー', 'id' => 'mixiユーザーID');
	my @errors;
	# データの生成とチェック
	my %form     = map { $_ => $values{$_} } @fields;
	$form{'id'}  = $self->parse_self_id;
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
	my $url       = exists($values{'__action__'}) ? $values{'__action__'} : 'edit_diary.pl?id=' . $values{'id'};
	my @fields    = qw(submit diary_title diary_body form_date photo1 photo2 photo3 orig_size post_key);
	my @required  = qw(submit diary_title diary_body post_key);
	my @files     = qw(photo1 photo2 photo3);
	my %label     = ('id' => '日記ID', 'diary_title' => '日記のタイトル', 'diary_body' => '日記の本文', 'photo1' => '写真1', 'photo2' => '写真2', 'photo3' => '写真3', 'post_key' => '送信キー');
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
	$mixi->dumper_log({'テストレコード' => $mixi->{'__test_record'}, 'テストリンク' => $mixi->{'__test_link'}});
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
			my $log_level = 0;
			if    ($log !~ /^(\s|\[.*?\])/) { $log_level = 1; }
			elsif ($log =~ /^\[error\]/)    { $log_level = 1; $error = 1; }
			elsif ($log =~ /^\[usage\]/)    { $log_level = 1; }
			elsif ($log =~ /^\[warn\]/)     { $log_level = 1; }
			elsif ($log =~ /^\[info\]/)     { $log_level = 1; }
			elsif ($log =~ /^\s/)           { $log_level = 2; }
			else                            { $log_level = 2; }
			if ($log_level) { 
				eval '$log = jcode($log, "euc")->sjis' if ($use_jcode);
				print OUT $log;
				print $log if ($log_level <= 1);
			}
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

sub test_link {
	my $mixi = shift;
	$mixi->{'__test_link'} = {} unless (ref($mixi->{'__test_link'}) eq 'HASH');
	if (@_ == 0) {
		return sort { $a cmp $b } (keys(%{$mixi->{'__test_link'}}));
	} elsif (@_ == 1) {
		my $key = shift;
		return $mixi->{'__test_link'}->{$key};
	} else {
		my $key = shift;
		foreach my $item (grep { ref($_) eq 'HASH' } @_) {
			foreach (values(%{$item})) {
				foreach my $value (ref($_) eq 'HASH' ? values(%{$_}) : $_) {
					next if (ref($value) ne '' or $value =~ /\s/);
					next if ($value !~ /^https?:\/\/(?:[^\/]*].)?mixi.jp\/(?:[^\?]*\/)?([^\/\?]+).*$/);
					next if ($mixi->{'__test_link'}->{$1});
					$mixi->{'__test_link'}->{$1} = $value;
				}
			}
		}
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
		'home_new_album'          => {'label' => 'ホームのマイミクシィ最新アルバム'},
		'home_new_bbs'            => {'label' => 'ホームのコミュニティ最新書き込み'},
		'home_new_comment'        => {'label' => 'ホームの日記コメント記入履歴'},
		'home_new_friend_diary'   => {'label' => 'ホームのマイミクシィ最新日記'},
		'home_new_review'         => {'label' => 'ホームのマイミクシィ最新レビュー'},
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
		'ajax_new_diary'          => {'label' => 'マイミクシィの最新日記（Ajax版）', 'url' => sub { return $_[0]->test_link('ajax_new_diary.pl') }},
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
		'show_intro'              => {'label' => 'マイミクシィからの紹介文'},
		'show_log'                => {'label' => 'あしあと'},
		'show_log_count'          => {'label' => 'あしあと数'},
		# コンテンツ
		'view_album'              => {'label' => 'フォトアルバム',           'url' => sub { return $_[0]->test_record('new_album')}},
		'view_album_photo'        => {'label' => 'フォトアルバムの写真',     'url' => sub { $_ = $_[0]->test_record('new_album'); return ref($_) eq 'HASH' ? $_->{'link'} : undef }},
		'view_album_comment'      => {'label' => 'フォトアルバムのコメント', 'url' => sub { $_ = $_[0]->test_record('new_album'); return ref($_) eq 'HASH' ? $_->{'link'} . '&mode=comment' : undef }},
		'view_diary'              => {'label' => '日記(詳細)',               'url' => sub { return $_[0]->test_record('list_diary')}},
		'view_event'              => {'label' => 'イベント',                 'url' => sub { return $_[0]->test_link('view_event.pl')}},
		'view_message'            => {'label' => 'メッセージ(詳細)',         'url' => sub { return $_[0]->test_record('list_message')}},
		# コミュニティ関連
		'community_id'            => {'label' => 'コミュニティID',           'url' => sub { return $_[0]->test_record('list_community')}},
		'list_bbs'                => {'label' => 'トピック一覧',             'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_bbs_next'           => {'label' => 'トピック一覧(次)',         'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_bbs_previous'       => {'label' => 'トピック一覧(前)',         'url' => sub { return $_[0]->test_record('list_bbs_next')}},
		'list_member'             => {'label' => 'メンバー一覧',             'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_member_next'        => {'label' => 'メンバー一覧(次)',         'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		'list_member_previous'    => {'label' => 'メンバー一覧(前)',         'url' => sub { return $_[0]->test_record('list_member_next')}},
		'edit_member'             => {'label' => 'メンバー管理',             'arg' => ['id' => 43735]},
		'edit_member_pages'       => {'label' => 'メンバー管理(ページ一覧)', 'arg' => ['id' => 43735]},
		'view_bbs'                => {'label' => 'トピック',                 'url' => sub { return $_[0]->test_record('list_bbs')}},
#		'view_community'          => {'label' => 'コミュニティ',             'arg' => ['id' => sub { return $_[0]->test_record('community_id')}]},
		# 日記の編集
		'edit_diary_preview'      => {'label' => '日記(編集)',       'url' => sub { return $_[0]->test_record('list_diary')}},
	);
	while (@tests >= 2) {
		my ($test, $opt) = splice(@tests, 0, 2);
		my $method = "get_$test";
		my $label  = $opt->{'label'};
		my $url    = defined($opt->{'url'}) ? $opt->{'url'} : '';
		if (ref($url) eq 'CODE') {
			$url   = &{$url}($mixi);
			unless ($url) {
				$mixi->log("$labelをスキップします。\n", "[warn] 参照レコードなし\n");
				next;
			}
		}
		$url       = $url->{'link'} if (ref($url) eq 'HASH');
		my @arg    = (defined($opt->{'arg'}) and ref($opt->{'arg'})) eq 'ARRAY' ? @{$opt->{'arg'}} : ();
		@arg       = map { ref($_) eq 'CODE' ? &{$_}($mixi) : $_ } @arg;
		unshift(@arg, $url) if (defined($url) and ref($url) eq '' and length($url));
		$mixi->log("$labelの取得と解析（$method）をします。\n");
		$mixi->log(qq([info] ターゲットURLは"$url"です。\n)) if ($url);
		my @items  = eval { $mixi->$method(@arg); };
		my $error  = ($@) ? $@ : ($mixi->response->is_error) ? $mixi->response->status_line : undef;
		if (defined $error) {
			$mixi->log("$labelの取得と解析に失敗しました。\n", "[error] $error\n");
			$mixi->dumper_log($mixi->response);
			exit 8;
		} else {
			if (@items) {
				$mixi->dumper_log([@items]);
				$mixi->test_link($test => @items);
				$mixi->test_record($test => $items[0]);
				$mixi->test_record($test => {'link' => 'http://mixi.jp/view_album.pl?id=150828'}) if ($test eq 'new_album');
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

Copyright 2004-2006 Makio Tsukamoto.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

