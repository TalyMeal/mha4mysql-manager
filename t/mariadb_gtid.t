use strict;
use warnings;

use FindBin;
use Test::More;

BEGIN {
  package MHA::SlaveUtil;

  sub get_version {
    my ($dbh) = @_;
    return $dbh->{server_version};
  }

  $INC{'MHA/SlaveUtil.pm'} = __FILE__;

  package MHA::NodeUtil;

  sub mysql_version_ge {
    my ( $actual, $minimum ) = @_;
    my @actual_versions = $actual =~ /(\d+)\.(\d+)\.(\d+)/g;
    my @actual = @actual_versions[-3 .. -1];
    my @minimum = $minimum =~ /(\d+)\.(\d+)\.(\d+)/;
    for my $index ( 0 .. 2 ) {
      return 1 if $actual[$index] > $minimum[$index];
      return 0 if $actual[$index] < $minimum[$index];
    }
    return 1;
  }

  $INC{'MHA/NodeUtil.pm'} = __FILE__;

  package MHA::ManagerConst;

  our @ALIVE_ERROR_CODES = ();
  our $MYSQL_UNKNOWN_TID = 1094;
  our $MYSQL_DEAD_RC = 10;

  $INC{'MHA/ManagerConst.pm'} = __FILE__;

  package Log::Dispatch;

  $INC{'Log/Dispatch.pm'} = __FILE__;

  package Parallel::ForkManager;

  $INC{'Parallel/ForkManager.pm'} = __FILE__;

  package MHA::HealthCheck;

  $INC{'MHA/HealthCheck.pm'} = __FILE__;

  package MHA::ManagerUtil;

  $INC{'MHA/ManagerUtil.pm'} = __FILE__;
}

use lib "$FindBin::Bin/../lib";

require MHA::DBHelper;
require MHA::Server;
require MHA::ServerManager;

{
  package Local::DBH;

  sub new {
    my ( $class, %args ) = @_;
    return bless {
      handler        => $args{handler},
      queries        => [],
      server_version => $args{server_version},
    }, $class;
  }

  sub prepare {
    my ( $self, $query ) = @_;
    push @{ $self->{queries} }, { query => $query, bind => [] };
    return bless {
      dbh   => $self,
      call  => $self->{queries}->[-1],
      query => $query,
    }, 'Local::STH';
  }

  sub queries {
    my ($self) = @_;
    return $self->{queries};
  }
}

{
  package Local::STH;

  sub execute {
    my ( $self, @bind ) = @_;
    $self->{call}->{bind} = \@bind;
    my $response = $self->{dbh}->{handler}->( $self->{query}, \@bind );
    $self->{response} = $response || {};
    return exists $self->{response}->{ret} ? $self->{response}->{ret} : 1;
  }

  sub fetchrow_hashref {
    my ($self) = @_;
    return $self->{response}->{row};
  }

  sub errstr {
    my ($self) = @_;
    return $self->{response}->{errstr};
  }
}

{
  package Local::Logger;

  sub new { return bless {}, shift; }
  sub info { return; }
  sub debug { return; }
  sub error { return; }
}

{
  package Local::CaptureLogger;

  sub new { return bless { errors => [] }, shift; }
  sub info { return; }
  sub debug { return; }
  sub error {
    my ( $self, $message ) = @_;
    push @{ $self->{errors} }, $message;
    return;
  }
}

{
  package Local::StatusHelper;

  sub new {
    return bless { is_mariadb => 1 }, shift;
  }

  sub set_long_wait_timeout { return 0; }
  sub get_server_id { return 101; }
  sub get_version { return '10.11.8-MariaDB'; }
  sub has_gtid { return 1; }
  sub is_binlog_enabled { return 0; }
  sub is_log_slave_updates_enabled { return 1; }
  sub get_datadir { return '/var/lib/mysql'; }
  sub get_num_workers { return 8; }
  sub check_slave_status { return ( Status => 1 ); }
  sub is_read_only { return 0; }
  sub is_relay_log_purge { return 1; }
}

{
  package Local::StatusServer;

  our @ISA = ('MHA::Server');

  sub connect_check {
    my ($self) = @_;
    $self->{dbhelper} = $self->{test_dbhelper};
    $self->{dbh} = {};
    return 0;
  }
}

{
  package Local::ChangeMasterHelper;

  sub new {
    my ( $class, %args ) = @_;
    return bless { calls => [], %args }, $class;
  }

  sub reset_slave {
    my ($self) = @_;
    push @{ $self->{calls} }, ['reset_slave'];
    return 0;
  }

  sub change_master_gtid {
    my ( $self, @args ) = @_;
    push @{ $self->{calls} }, [ 'change_master_gtid', @args ];
    return $self->{gtid_error} || 0;
  }

  sub change_master {
    my ( $self, @args ) = @_;
    push @{ $self->{calls} }, [ 'change_master', @args ];
    return 0;
  }
}

{
  package Local::ManagedServer;

  sub new {
    my ( $class, %args ) = @_;
    return bless \%args, $class;
  }

  sub get_hostinfo {
    my ($self) = @_;
    return "$self->{hostname}:$self->{port}";
  }

  sub stop_slave {
    my ($self) = @_;
    push @{ $self->{server_calls} }, 'stop_slave';
    return 0;
  }

  sub start_slave {
    my ($self) = @_;
    push @{ $self->{server_calls} }, 'start_slave';
    return 0;
  }

  sub disable_relay_log_purge {
    my ($self) = @_;
    push @{ $self->{server_calls} }, 'disable_relay_log_purge';
    return 0;
  }
}

{
  package Local::SyncServer;

  sub new {
    my ( $class, %args ) = @_;
    my $self = bless { calls => [], %args }, $class;
    $self->{dbhelper} = $self unless ( $self->{dbhelper} );
    return $self;
  }

  sub get_binlog_position {
    return (
      'mariadb-bin.000009', 777, '', '',
      '0-1-100,1-7-20',
    );
  }

  sub show_master_status {
    my ($self) = @_;
    return $self->get_binlog_position();
  }

  sub gtid_wait {
    my ( $self, @args ) = @_;
    push @{ $self->{calls} }, [ 'gtid_wait', @args ];
    return 0;
  }

  sub master_pos_wait {
    my ( $self, @args ) = @_;
    push @{ $self->{calls} }, [ 'master_pos_wait', @args ];
    return 0;
  }
}

sub dbh_with_responses {
  my (%responses) = @_;
  return Local::DBH->new(
    handler => sub {
      my ( $query, $bind ) = @_;
      for my $pattern ( keys %responses ) {
        return $responses{$pattern} if $query =~ /$pattern/;
      }
      return { ret => '0E0' };
    },
  );
}

sub mariadb_slave_row {
  my (%overrides) = @_;
  return {
    Slave_IO_State              => 'Waiting for master to send event',
    Master_Host                 => 'db-primary',
    Master_Port                 => 3306,
    Master_User                 => 'repl',
    Slave_IO_Running            => 'Yes',
    Slave_SQL_Running           => 'Yes',
    Last_IO_Errno               => 0,
    Last_IO_Error               => '',
    Master_Log_File             => 'mariadb-bin.000004',
    Read_Master_Log_Pos         => 1234,
    Relay_Master_Log_File       => 'mariadb-bin.000004',
    Last_Errno                  => 0,
    Last_Error                  => '',
    Exec_Master_Log_Pos         => 1234,
    Relay_Log_File              => 'relay-bin.000008',
    Relay_Log_Pos               => 1497,
    Seconds_Behind_Master       => 0,
    Replicate_Do_DB             => '',
    Replicate_Ignore_DB         => '',
    Replicate_Do_Table          => '',
    Replicate_Ignore_Table      => '',
    Replicate_Wild_Do_Table     => '',
    Replicate_Wild_Ignore_Table => '',
    Using_Gtid                  => 'Slave_Pos',
    Gtid_IO_Pos                 => '0-1-100,1-7-20',
    %overrides,
  };
}

subtest 'server vendor detection' => sub {
  my $mariadb_dbh = Local::DBH->new(
    server_version => '10.11.8-MariaDB-0ubuntu0.24.04.1',
    handler        => sub { return { ret => 1, row => {} }; },
  );
  my $mariadb = MHA::DBHelper->new( dbh => $mariadb_dbh );

  is(
    $mariadb->get_version(),
    '10.11.8-MariaDB-0ubuntu0.24.04.1',
    'MariaDB version is returned unchanged',
  );
  ok( $mariadb->{is_mariadb}, 'MariaDB vendor is remembered by DBHelper' );

  my $mysql_dbh = Local::DBH->new(
    server_version => '8.0.40',
    handler        => sub { return { ret => 1, row => {} }; },
  );
  my $mysql = MHA::DBHelper->new( dbh => $mysql_dbh );
  is( $mysql->get_version(), '8.0.40', 'MySQL version is returned unchanged' );
  ok( !$mysql->{is_mariadb}, 'MySQL is not marked as MariaDB' );
};

subtest 'Server exposes the detected database vendor' => sub {
  my $server = Local::StatusServer->new();
  $server->{hostname} = 'db-primary';
  $server->{ip} = '192.0.2.11';
  $server->{port} = 3306;
  $server->{user} = 'mha';
  $server->{logger} = Local::Logger->new();
  $server->{test_dbhelper} = Local::StatusHelper->new();

  ok( $server->connect_and_get_status(), 'server status is collected' );
  ok( $server->{is_mariadb}, 'MariaDB vendor flag is copied from DBHelper' );
  ok(
    $server->{log_slave_updates},
    'log_slave_updates capability is copied from DBHelper',
  );
};

subtest 'MariaDB GTID capability does not depend on a non-empty position' => sub {
  my $dbh = Local::DBH->new(
    handler => sub {
      my ( $query, $bind ) = @_;
      if ( $query =~ /gtid_current_pos/i
        || grep { defined $_ && $_ eq 'gtid_current_pos' } @{$bind} )
      {
        return { ret => 1, row => { Value => '' } };
      }
      return { ret => 1, row => { Value => 'OFF' } };
    },
  );
  my $helper = MHA::DBHelper->new( dbh => $dbh, is_mariadb => 1 );

  ok( $helper->has_gtid(), 'readable empty gtid_current_pos is GTID capable' );
  ok( $helper->{has_gtid}, 'capability is cached on the helper' );
  unlike(
    join( '\n', map { $_->{query} } @{ $dbh->queries() } ),
    qr/gtid_mode/,
    'MariaDB capability check does not query MySQL gtid_mode',
  );
};

subtest 'unsupported MariaDB GTID capability is reported without warnings' => sub {
  my $dbh = Local::DBH->new(
    handler => sub {
      return {
        ret    => undef,
        row    => undef,
        errstr => 'Unknown system variable',
      };
    },
  );
  my $helper = MHA::DBHelper->new( dbh => $dbh, is_mariadb => 1 );

  my ( $error, $has_gtid );
  {
    local $@;
    eval { $has_gtid = $helper->has_gtid(); 1 } or $error = $@;
  }
  is( $error, undef, 'missing MariaDB GTID variable does not die' );
  ok( !$has_gtid, 'server without the GTID variable is not GTID capable' );
};

subtest 'MySQL GTID capability keeps existing behavior' => sub {
  my $dbh = dbh_with_responses(
    'gtid_mode' => { ret => 1, row => { Value => 'ON' } },
  );
  my $helper = MHA::DBHelper->new( dbh => $dbh, is_mariadb => 0 );

  ok( $helper->has_gtid(), 'MySQL gtid_mode=ON is supported' );
  like(
    join( '\n', map { $_->{query} } @{ $dbh->queries() } ),
    qr/gtid_mode/,
    'MySQL uses its native gtid_mode capability check',
  );

  my $disabled_dbh = dbh_with_responses(
    'gtid_mode' => { ret => 1, row => { Value => 'OFF' } },
  );
  my $disabled = MHA::DBHelper->new( dbh => $disabled_dbh, is_mariadb => 0 );
  ok( !$disabled->has_gtid(), 'MySQL gtid_mode=OFF remains disabled' );
};

subtest 'parallel worker variable is vendor-specific' => sub {
  my $mariadb_dbh = dbh_with_responses(
    'slave_parallel_threads' => { ret => 1, row => { Value => 8 } },
  );
  my $mariadb = MHA::DBHelper->new( dbh => $mariadb_dbh, is_mariadb => 1 );
  is( $mariadb->get_num_workers(), 8, 'MariaDB parallel thread count is returned' );
  like(
    join( '\n', map { $_->{query} } @{ $mariadb_dbh->queries() } ),
    qr/slave_parallel_threads/,
    'MariaDB queries slave_parallel_threads',
  );
  unlike(
    join( '\n', map { $_->{query} } @{ $mariadb_dbh->queries() } ),
    qr/slave_parallel_workers/,
    'MariaDB does not query the MySQL worker variable',
  );

  my $mysql_dbh = dbh_with_responses(
    'slave_parallel_workers' => { ret => 1, row => { Value => 4 } },
  );
  my $mysql = MHA::DBHelper->new( dbh => $mysql_dbh, is_mariadb => 0 );
  is( $mysql->get_num_workers(), 4, 'MySQL parallel worker count is returned' );
  like(
    join( '\n', map { $_->{query} } @{ $mysql_dbh->queries() } ),
    qr/slave_parallel_workers/,
    'MySQL keeps slave_parallel_workers',
  );
};

subtest 'log_slave_updates is detected for GTID candidate safety' => sub {
  my $enabled_dbh = dbh_with_responses(
    'log_slave_updates' => { ret => 1, row => { Value => 1 } },
  );
  my $enabled = MHA::DBHelper->new( dbh => $enabled_dbh );
  ok( $enabled->is_log_slave_updates_enabled(), 'enabled value is recognized' );

  my $enabled_text_dbh = dbh_with_responses(
    'log_slave_updates' => { ret => 1, row => { Value => 'ON' } },
  );
  my $enabled_text = MHA::DBHelper->new( dbh => $enabled_text_dbh );
  ok(
    $enabled_text->is_log_slave_updates_enabled(),
    'textual ON value is recognized',
  );

  my $disabled_dbh = dbh_with_responses(
    'log_slave_updates' => { ret => 1, row => { Value => 0 } },
  );
  my $disabled = MHA::DBHelper->new( dbh => $disabled_dbh );
  ok(
    !$disabled->is_log_slave_updates_enabled(),
    'disabled value is recognized',
  );
};

subtest 'MariaDB slave status is normalized for failover code' => sub {
  my $dbh = dbh_with_responses(
    '^SHOW SLAVE STATUS$' => {
      ret => 1,
      row => mariadb_slave_row(),
    },
    'gtid_slave_pos' => {
      ret => 1,
      row => { Value => '0-1-100,1-7-20' },
    },
  );
  my $helper = MHA::DBHelper->new( dbh => $dbh, is_mariadb => 1 );
  my %status = $helper->check_slave_status();

  is( $status{Status}, 0, 'replica status is valid' );
  is( $status{Using_Gtid}, 'Slave_Pos', 'MariaDB GTID mode is preserved' );
  is(
    $status{Gtid_IO_Pos},
    '0-1-100,1-7-20',
    'MariaDB received position is preserved',
  );
  is(
    $status{Retrieved_Gtid_Set},
    '0-1-100,1-7-20',
    'received position is normalized for common failover code',
  );
  is(
    $status{Executed_Gtid_Set},
    '0-1-100,1-7-20',
    'executed position comes from gtid_slave_pos',
  );
  is( $status{Auto_Position}, 1, 'Slave_Pos enables GTID auto-positioning' );

  my $current_pos_dbh = dbh_with_responses(
    '^SHOW SLAVE STATUS$' => {
      ret => 1,
      row => mariadb_slave_row( Using_Gtid => 'Current_Pos' ),
    },
    'gtid_slave_pos' => {
      ret => 1,
      row => { Value => '0-1-100,1-7-20' },
    },
  );
  my $current_pos =
    MHA::DBHelper->new( dbh => $current_pos_dbh, is_mariadb => 1 );
  my %current_pos_status = $current_pos->check_slave_status();
  is(
    $current_pos_status{Auto_Position},
    1,
    'Current_Pos also enables GTID auto-positioning',
  );
};

subtest 'MariaDB non-GTID channel and undefined GTID fields are safe' => sub {
  my $dbh = dbh_with_responses(
    '^SHOW SLAVE STATUS$' => {
      ret => 1,
      row => mariadb_slave_row(
        Using_Gtid  => 'No',
        Gtid_IO_Pos => undef,
      ),
    },
    'gtid_slave_pos' => { ret => 1, row => { Value => undef } },
  );
  my $helper = MHA::DBHelper->new( dbh => $dbh, is_mariadb => 1 );

  my ( $error, %status );
  {
    local $@;
    eval { %status = $helper->check_slave_status(); 1 } or $error = $@;
  }
  is( $error, undef, 'undefined MariaDB GTID fields do not trigger fatal warnings' );
  is( $status{Auto_Position}, 0, 'Using_Gtid=No disables auto-positioning' );
  ok( !defined $status{Retrieved_Gtid_Set}, 'undefined IO position stays undefined' );
  ok( !defined $status{Executed_Gtid_Set}, 'undefined slave position stays undefined' );

  my $undef_dbh = dbh_with_responses(
    '^SHOW SLAVE STATUS$' => {
      ret => 1,
      row => mariadb_slave_row(
        Using_Gtid  => undef,
        Gtid_IO_Pos => undef,
      ),
    },
    'gtid_slave_pos' => { ret => 1, row => { Value => undef } },
  );
  my $undef_helper = MHA::DBHelper->new( dbh => $undef_dbh, is_mariadb => 1 );
  my $undef_error;
  {
    local $@;
    eval { $undef_helper->check_slave_status(); 1 } or $undef_error = $@;
  }
  is( $undef_error, undef, 'undefined Using_Gtid does not trigger a fatal warning' );
};

subtest 'replication IO startup errors are reported immediately' => sub {
  my $logger = Local::CaptureLogger->new();
  my $dbh = dbh_with_responses(
    '^SHOW SLAVE STATUS$' => {
      ret => 1,
      row => mariadb_slave_row(
        Slave_IO_Running  => 'No',
        Slave_SQL_Running => 'Yes',
        Last_IO_Errno     => 1236,
        Last_IO_Error     => 'requested GTID is not in the master binlog',
      ),
    },
    'gtid_slave_pos' => { ret => 1, row => { Value => '0-1-100' } },
  );
  my $server = bless {
    dbhelper => MHA::DBHelper->new( dbh => $dbh, is_mariadb => 1 ),
    hostname => 'db-replica',
    ip       => '192.0.2.42',
    port     => 3306,
    logger   => $logger,
    has_gtid => 1,
  }, 'MHA::Server';

  is(
    $server->wait_until_slave_starts('ALL'),
    1,
    'an IO error stops the startup wait',
  );
  like(
    join( "\n", @{ $logger->{errors} } ),
    qr/1236.*requested GTID is not in the master binlog/s,
    'the MariaDB GTID IO error is logged',
  );
};

subtest 'MariaDB master position uses native GTID format' => sub {
  my $dbh = dbh_with_responses(
    '^SHOW MASTER STATUS$' => {
      ret => 1,
      row => {
        File             => 'mariadb-bin.000009',
        Position         => 777,
        Binlog_Do_DB     => '',
        Binlog_Ignore_DB => '',
      },
    },
    'gtid_binlog_pos' => {
      ret => 1,
      row => { Value => '0-1-100,1-7-20' },
    },
  );
  my $helper = MHA::DBHelper->new( dbh => $dbh, is_mariadb => 1 );
  my ( $file, $position, undef, undef, $gtid ) = $helper->show_master_status();

  is( $file, 'mariadb-bin.000009', 'binlog file is returned' );
  is( $position, 777, 'binlog position is returned' );
  is( $gtid, '0-1-100,1-7-20', 'multi-domain MariaDB GTID is returned verbatim' );
};

subtest 'change_master_gtid selects vendor-specific syntax' => sub {
  my $mariadb_dbh = dbh_with_responses();
  my $mariadb = MHA::DBHelper->new( dbh => $mariadb_dbh, is_mariadb => 1 );
  is(
    $mariadb->change_master_gtid( 'db-primary', 3307, 'repl', 'secret' ),
    0,
    'MariaDB CHANGE MASTER succeeds',
  );
  my $mariadb_sql = $mariadb_dbh->queries()->[-1]->{query};
  like( $mariadb_sql, qr/MASTER_USE_GTID=slave_pos/, 'uses slave_pos' );
  unlike( $mariadb_sql, qr/MASTER_AUTO_POSITION/, 'does not use MySQL auto-position' );
  like( $mariadb_sql, qr/MASTER_PASSWORD='secret'/, 'password is included' );

  my $mariadb_no_pass_dbh = dbh_with_responses();
  my $mariadb_no_pass =
    MHA::DBHelper->new( dbh => $mariadb_no_pass_dbh, is_mariadb => 1 );
  $mariadb_no_pass->change_master_gtid( 'db-primary', 3307, 'repl', '' );
  my $mariadb_no_pass_sql = $mariadb_no_pass_dbh->queries()->[-1]->{query};
  like( $mariadb_no_pass_sql, qr/MASTER_USE_GTID=slave_pos/, 'no-password form uses slave_pos' );
  unlike( $mariadb_no_pass_sql, qr/MASTER_PASSWORD/, 'empty password is omitted' );

  my $mysql_dbh = dbh_with_responses();
  my $mysql = MHA::DBHelper->new( dbh => $mysql_dbh, is_mariadb => 0 );
  $mysql->change_master_gtid( 'db-primary', 3307, 'repl', 'secret' );
  my $mysql_sql = $mysql_dbh->queries()->[-1]->{query};
  like( $mysql_sql, qr/MASTER_AUTO_POSITION=1/, 'MySQL keeps auto-position syntax' );
  unlike( $mysql_sql, qr/MASTER_USE_GTID/, 'MySQL does not use MariaDB syntax' );
};

subtest 'MariaDB demotion syntax follows server version' => sub {
  my $mariadb12_dbh = Local::DBH->new(
    server_version => '12.1.2-MariaDB',
    handler        => sub { return { ret => '0E0' }; },
  );
  my $mariadb12 = MHA::DBHelper->new( dbh => $mariadb12_dbh );
  $mariadb12->get_version();
  $mariadb12->change_master_gtid(
    'db-primary', 3307, 'repl', 'secret', 1,
  );
  like(
    $mariadb12_dbh->queries()->[-1]->{query},
    qr/MASTER_DEMOTE_TO_SLAVE=1/,
    'MariaDB 12.x uses atomic demotion option',
  );

  my $modern_dbh = Local::DBH->new(
    server_version => '10.11.8-MariaDB',
    handler        => sub { return { ret => '0E0' }; },
  );
  my $modern = MHA::DBHelper->new( dbh => $modern_dbh );
  $modern->get_version();
  $modern->change_master_gtid( 'db-primary', 3307, 'repl', 'secret', 1 );
  my $modern_sql = $modern_dbh->queries()->[-1]->{query};
  like(
    $modern_sql,
    qr/MASTER_DEMOTE_TO_SLAVE=1/,
    'MariaDB 10.10+ uses atomic demotion option',
  );
  unlike(
    $modern_sql,
    qr/MASTER_USE_GTID=current_pos/,
    'modern demotion does not use the compatibility fallback',
  );

  my $legacy_dbh = Local::DBH->new(
    server_version => '10.6.18-MariaDB',
    handler        => sub { return { ret => '0E0' }; },
  );
  my $legacy = MHA::DBHelper->new( dbh => $legacy_dbh );
  $legacy->get_version();
  $legacy->change_master_gtid( 'db-primary', 3307, 'repl', 'secret', 1 );
  my $legacy_sql = $legacy_dbh->queries()->[-1]->{query};
  like(
    $legacy_sql,
    qr/MASTER_USE_GTID=current_pos/,
    'older MariaDB uses current_pos for demotion',
  );
  unlike(
    $legacy_sql,
    qr/MASTER_DEMOTE_TO_SLAVE/,
    'older MariaDB does not use unsupported demotion syntax',
  );

  my $compat_dbh = Local::DBH->new(
    server_version => '5.5.5-10.11.9-MariaDB',
    handler        => sub { return { ret => '0E0' }; },
  );
  my $compat = MHA::DBHelper->new( dbh => $compat_dbh );
  $compat->get_version();
  $compat->change_master_gtid( 'db-primary', 3307, 'repl', 'secret', 1 );
  like(
    $compat_dbh->queries()->[-1]->{query},
    qr/MASTER_DEMOTE_TO_SLAVE=1/,
    'MariaDB compatibility version prefix is parsed correctly',
  );

  my $mysql_dbh = Local::DBH->new(
    server_version => '8.0.40',
    handler        => sub { return { ret => '0E0' }; },
  );
  my $mysql = MHA::DBHelper->new( dbh => $mysql_dbh );
  $mysql->get_version();
  $mysql->change_master_gtid( 'db-primary', 3307, 'repl', 'secret', 1 );
  like(
    $mysql_dbh->queries()->[-1]->{query},
    qr/MASTER_AUTO_POSITION=1/,
    'demotion flag does not change MySQL GTID syntax',
  );
};

subtest 'gtid_wait selects vendor-specific function and preserves GTID' => sub {
  my $mariadb_dbh = dbh_with_responses(
    'MASTER_GTID_WAIT' => { ret => 1, row => { Result => 0 } },
  );
  my $mariadb = MHA::DBHelper->new( dbh => $mariadb_dbh, is_mariadb => 1 );
  is( $mariadb->gtid_wait('0-1-100,1-7-20'), 0, 'MariaDB wait succeeds' );
  my $mariadb_call = $mariadb_dbh->queries()->[-1];
  like(
    $mariadb_call->{query},
    qr/MASTER_GTID_WAIT\(\?,\s*-1\)/,
    'MariaDB uses an unlimited MASTER_GTID_WAIT',
  );
  is_deeply(
    $mariadb_call->{bind},
    ['0-1-100,1-7-20'],
    'multi-domain GTID is bound without parsing',
  );

  my $mysql_dbh = dbh_with_responses(
    'WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS' => {
      ret => 1,
      row => { Result => 3 },
    },
  );
  my $mysql = MHA::DBHelper->new( dbh => $mysql_dbh, is_mariadb => 0 );
  is( $mysql->gtid_wait('uuid:1-10'), 3, 'MySQL wait result is preserved' );
  like(
    $mysql_dbh->queries()->[-1]->{query},
    qr/WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS/,
    'MySQL keeps its native wait function',
  );
};

subtest 'GTID failover policy uses normalized MariaDB status' => sub {
  my $manager = MHA::ServerManager->new(
    alive_servers => [
      { has_gtid => 1, is_mariadb => 1 },
      {
        has_gtid          => 1,
        is_mariadb        => 1,
        Using_Gtid       => 'Slave_Pos',
        Auto_Position    => 1,
        Executed_Gtid_Set => '0-1-100,1-7-20',
      },
    ],
    alive_slaves => [
      {
        has_gtid          => 1,
        is_mariadb        => 1,
        Using_Gtid       => 'Slave_Pos',
        Auto_Position    => 1,
        Executed_Gtid_Set => '0-1-100,1-7-20',
      },
    ],
  );
  is( $manager->get_gtid_status(), 1, 'Slave_Pos selects GTID failover mode' );

  $manager->{alive_servers}->[1]->{Using_Gtid} = 'No';
  $manager->{alive_servers}->[1]->{Auto_Position} = 0;
  $manager->{alive_slaves}->[0]->{Using_Gtid} = 'No';
  $manager->{alive_slaves}->[0]->{Auto_Position} = 0;
  is( $manager->get_gtid_status(), 2, 'Using_Gtid=No does not enable auto-position' );

  my $mixed = MHA::ServerManager->new(
    alive_servers => [
      { has_gtid => 1, is_mariadb => 0 },
      {
        has_gtid           => 1,
        is_mariadb         => 1,
        Auto_Position      => 1,
        Executed_Gtid_Set  => '0-1-100',
      },
    ],
    alive_slaves => [
      {
        has_gtid           => 1,
        is_mariadb         => 1,
        Auto_Position      => 1,
        Executed_Gtid_Set  => '0-1-100',
      },
    ],
  );
  is( $mixed->get_gtid_status(), 0, 'mixed MySQL/MariaDB GTID topology is rejected' );
};

subtest 'MariaDB GTID synchronization does not use file and position' => sub {
  my $manager = MHA::ServerManager->new(
    gtid_failover_mode => 1,
    logger             => Local::Logger->new(),
  );
  my $advanced = Local::SyncServer->new( is_mariadb => 1 );
  my $waiter = Local::SyncServer->new( is_mariadb => 1 );

  is( $manager->wait_until_in_sync( $waiter, $advanced ), 0, 'wait succeeds' );
  my @method_names = map { $_->[0] } @{ $waiter->{calls} };
  my $gtid_calls = grep { $_ eq 'gtid_wait' } @method_names;
  my $file_pos_calls = grep { $_ eq 'master_pos_wait' } @method_names;
  ok( $gtid_calls, 'waiter uses GTID synchronization' );
  ok( !$file_pos_calls, 'waiter does not use physical coordinates' );
  is(
    $waiter->{calls}->[0]->[1],
    '0-1-100,1-7-20',
    'new primary binlog GTID position is used as the barrier',
  );
};

subtest 'unsafe MariaDB GTID promotion candidate is excluded' => sub {
  my $unsafe = Local::ManagedServer->new(
    id                       => 2,
    no_master                => 0,
    log_bin                  => 1,
    log_slave_updates        => 0,
    oldest_major_version     => 1,
    is_mariadb               => 1,
  );
  my $manager = MHA::ServerManager->new(
    gtid_failover_mode => 1,
    alive_slaves       => [$unsafe],
    logger             => Local::Logger->new(),
  );

  my @bad = $manager->get_bad_candidate_masters( undef, 0 );
  is_deeply(
    [ map { $_->{id} } @bad ],
    [2],
    'replica without log_slave_updates cannot become a GTID primary',
  );
};

subtest 'ServerManager reparents MariaDB through GTID' => sub {
  my $dbhelper = Local::ChangeMasterHelper->new();
  my $target = Local::ManagedServer->new(
    id                         => 2,
    hostname                   => 'db-replica',
    ip                         => '192.0.2.12',
    port                       => 3306,
    not_slave                  => 0,
    has_gtid                   => 1,
    is_mariadb                 => 1,
    relay_purge                => 1,
    use_ip_for_change_master   => 0,
    dbhelper                   => $dbhelper,
    server_calls               => [],
  );
  my $master = Local::ManagedServer->new(
    id            => 1,
    hostname      => 'db-primary',
    ip            => '192.0.2.11',
    port          => 3307,
    repl_user     => 'repl',
    repl_password => 'secret',
  );
  my $manager = MHA::ServerManager->new(
    gtid_failover_mode => 1,
    logger             => Local::Logger->new(),
  );

  is(
    $manager->change_master_and_start_slave(
      $target, $master, 'mariadb-bin.000001', 4,
    ),
    0,
    'MariaDB replica is started',
  );
  my @method_names = map { $_->[0] } @{ $dbhelper->{calls} };
  my $gtid_calls = grep { $_ eq 'change_master_gtid' } @method_names;
  my $file_pos_calls = grep { $_ eq 'change_master' } @method_names;
  ok( $gtid_calls, 'GTID reparent method is called' );
  ok( !$file_pos_calls, 'physical file/position reparent is not used' );
};

subtest 'ServerManager forwards the MariaDB demotion mode' => sub {
  my $dbhelper = Local::ChangeMasterHelper->new();
  my $target = Local::ManagedServer->new(
    id                       => 2,
    hostname                 => 'db-old-primary',
    ip                       => '192.0.2.12',
    port                     => 3306,
    not_slave                => 1,
    has_gtid                 => 1,
    is_mariadb               => 1,
    relay_purge              => 1,
    use_ip_for_change_master => 0,
    dbhelper                 => $dbhelper,
    server_calls             => [],
  );
  my $master = Local::ManagedServer->new(
    id            => 1,
    hostname      => 'db-new-primary',
    ip            => '192.0.2.11',
    port          => 3307,
    repl_user     => 'repl',
    repl_password => 'secret',
  );
  my $manager = MHA::ServerManager->new(
    gtid_failover_mode => 1,
    logger             => Local::Logger->new(),
  );

  is(
    $manager->change_master_and_start_slave(
      $target, $master, undef, undef, undef, 1,
    ),
    0,
    'demoted primary is started as a replica',
  );
  my ($change_call) =
    grep { $_->[0] eq 'change_master_gtid' } @{ $dbhelper->{calls} };
  ok( $change_call, 'GTID reparent call is recorded' );
  is( $change_call->[5], 1, 'demotion flag reaches DBHelper' );
};

subtest 'failed GTID reparent does not start the replica' => sub {
  my $dbhelper =
    Local::ChangeMasterHelper->new( gtid_error => 'synthetic SQL error' );
  my $target = Local::ManagedServer->new(
    id                       => 2,
    hostname                 => 'db-replica',
    ip                       => '192.0.2.12',
    port                     => 3306,
    not_slave                => 0,
    has_gtid                 => 1,
    is_mariadb               => 1,
    relay_purge              => 1,
    use_ip_for_change_master => 0,
    dbhelper                 => $dbhelper,
    server_calls             => [],
  );
  my $master = Local::ManagedServer->new(
    id            => 1,
    hostname      => 'db-primary',
    ip            => '192.0.2.11',
    port          => 3307,
    repl_user     => 'repl',
    repl_password => 'secret',
  );
  my $manager = MHA::ServerManager->new(
    gtid_failover_mode => 1,
    logger             => Local::Logger->new(),
  );

  is(
    $manager->change_master_and_start_slave(
      $target, $master, 'mariadb-bin.000001', 4,
    ),
    1,
    'CHANGE MASTER error is returned to the caller',
  );
  my $start_calls = grep { $_ eq 'start_slave' } @{ $target->{server_calls} };
  ok( !$start_calls, 'replica is not started after failed CHANGE MASTER' );
};

done_testing();
