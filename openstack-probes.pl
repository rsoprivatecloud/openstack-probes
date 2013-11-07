#!$NIM_BIN/perl

###########################################################
# I Stoled Rick's mysql replication probe and added to it.
# I hope you don't mind Rick.
# Jake
###########################################################

use strict;
use Getopt::Std;
use Nimbus::API;
use Nimbus::Session;
use Nimbus::CFG;
use Data::Dumper;
$| = 1;

my $prgname = 'openstack-probes';
my $version = '0.1';
my $sub_sys = '1.1.1';
my $config;
my %options;

sub suppression_active {
    my ($_sec, $_min, $_hour) = localtime();
    my $current_min = ($_hour * 60) + $_min;
    my $_supp = $config->{'suppression'};
    foreach my $_interval_name (keys(%{$config->{'suppression'}})) {
        my $interval = $config->{'suppression'}->{$_interval_name};
        if (($interval->{'active'} =~ /no/i) || ($interval->{'active'} !~ /yes/i)) {
            next;
        }
        my ($_st_hour, $_st_min) = $interval->{'start'} =~ /(\d+):(\d+)/;
        my ($_end_hour, $_end_min) = $interval->{'end'} =~ /(\d+):(\d+)/;
        if (!defined($_st_hour) || !defined($_st_min) ||
            !defined($_end_hour) || !defined($_end_min)) {
            nimLog(1, "Invalid format in suppression interval '$_interval_name'");
            next;
        }
        my $start_mins = ($_st_hour * 60) + $_st_min;
        my $end_mins = ($_end_hour * 60) + $_end_min;
        if (($current_min >= $start_mins) && ($current_min < $end_mins)) {
            return $_interval_name;
        }
    }
    return undef;    
}

sub checkRabbit {
    if ( -e '/etc/init.d/rabbitmq-server' ) {
        nimLog(1, "RabbitMQ detected. Checking status...");
        my @data = `$config->{'setup'}->{'rabbitmq_cmd_line'} list_queues 2>/dev/null`;
        if ($? != 0) {
            $config->{'status'}->{'rabbit'}->{'samples'}++;
            if ($config->{'status'}->{'rabbit'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                $config->{'status'}->{'RabbitConnection'}->{'nimalarm_id'} = nimAlarm( $config->{'messages'}->{'RabbitConnection'}->{'level'},
                    $config->{'messages'}->{'RabbitConnection'}->{'text'}, $sub_sys, $config->{'messages'}->{'RabbitConnection'}->{'supp_str'});
                nimLog(1, "Rabbit alarm id : ".$config->{'status'}->{'RabbitConnection'}->{'nimalarm_id'});
            }
            return;
        } else {
            $config->{'status'}->{'rabbit'}->{'samples'} = 0;
            nimLog(3, "RabbitMQ connectivity alert clear");
            $config->{'status'}->{'RabbitConnection'}->{'nimalarm_id'} = nimAlarm( NIML_CLEAR, 'RabbitMQ connection established',
                $sub_sys, $config->{'messages'}->{'DatabaseConnection'}->{'supp_str'});
            nimLog(3, "RabbitMQ clear id : ".$config->{'status'}->{'RabbitConnection'}->{'nimalarm_id'});
        }
        nimLog(2, 'Returned '.scalar(@data).' lines from rabbitmqctl');
        my $queues_list = {};
        foreach my $line (@data) {
            my ($key, $value) = $line =~ /(?:^|\s+)(\S+)\s*\t\s*("[^"]*"|\S*)/;
            if (!defined($key) || !defined($value)) { next; }
            $queues_list->{$key} = $value;
        }
        while ( my ($key, $value) = each(%$queues_list) ) {
            if ($queues_list->{$key} >= $config->{'setup'}->{'Rabbit-WARN'}) {
                $config->{'status'}->{$key}->{'samples'}++;
                $config->{'status'}->{$key}->{'last'} = $queues_list->{$key};
                if ($config->{'status'}->{$key}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                    if ($queues_list->{$key} >= $config->{'setup'}->{'Rabbit-CRITICAL'}) {
                        nimLog(1, "Critical alert on message queue $key ($queues_list->{$key})");
                        my $alert_string = "RabbitMQ queue $key is not critically backed up with $queues_list->{$key} messages pending after $config->{'status'}->{$key}->{'samples'} samples.",;
                        $config->{'status'}->{$key}->{'nimalarm_id'} = nimAlarm( $config->{'messages'}->{'RabbitMQ_Crit'}->{'level'},
                            $alert_string, $sub_sys, $config->{'messages'}->{'RabbitMQ_Crit'}->{'supp_str'});
                    } else {
                        nimLog(1, "Warning alert on message queue $key ($queues_list->{$key})");
                        my $alert_string = "RabbitMQ queue $key is slightly backed up with $queues_list->{$key} messages pending after $config->{'status'}->{$key}->{'samples'} samples.",;
                        $config->{'status'}->{$key}->{'nimalarm_id'} = nimAlarm(
                            $config->{'messages'}->{'RabbitMQ_Warn'}->{'level'}, $alert_string, $sub_sys,
                            $config->{'messages'}->{'RabbitMQ_Warn'}->{'supp_str'});
                    }
                }
            } else {
                $config->{'status'}->{$key}->{'samples'} = 0;
                $config->{'status'}->{$key}->{'last'} = $queues_list->{$key};
                nimLog(3, "Clearing alert on RabbitMQ queue $key ($queues_list->{$key})");
                my $alert_string = "RabbitMQ alert on queue $key has cleared";
                $config->{'status'}->{'Seconds_Behind_Master'}->{'nimalarm_id'} = nimAlarm(
                    NIML_CLEAR, $alert_string, $sub_sys,
                    $config->{'messages'}->{'RabbitMQ_Warn'}->{'supp_str'});
            }
        }
    } else {
        nimLog(1, "RabbitMQ NOT detected. Skipping.");
    }
}

sub checkNova {
    if ( -e '/usr/bin/nova-manage' ) {
        nimLog(1, "Nova-Manage detected. Checking status...");
    } else {
        nimLog(1, "Nova-Manage NOT detected. Skipping.");
    }
}

sub checkNeutron {
    if ( -e '/usr/bin/neutron' ) {
        nimLog(1, "Neutron detected. Checking status...");
    } else {
        nimLog(1, "Neutron NOT detected. Skipping.");
    }
}

sub checkKeepalived {
    if ( -e '/etc/init.d/keepalived' ) {
        nimLog(1, "Keepalived detected. Checking status...");
    } else {
        nimLog(1, "Keepalived NOT detected. Skipping.");
    }
}

sub timeout {
    my $timestamp = time();
    if ($timestamp < $config->{'status'}->{'next_run'}) { return; }
    $config->{'status'}->{'next_run'} += $config->{'setup'}->{'interval'};
    nimLog(3, "($config->{'status'}->{'next_run'}) interval expired - running");
    #readConfig();
    startQoS();
    my $_s_active = suppression_active();
    if (defined($_s_active)) {
        nimLog(2, "Suppression interval '$_s_active' active");
        return;
    }
    checkRabbit();
    checkKeepalived();
    checkMysql();
    checkNova();
    checkNeutron();
}

sub checkMysql {
    if ( -e '/etc/init.d/mysql' || -e '/etc/init.d/mysqld' ) {
        nimLog(1, "Mysql detected. Checking status...");
        my $_exec = initialize_mysql_exec();
        if (!defined($_exec)) {
            nimLog(0, "Execution or authentication error - cannot perform replication query");
            return;
        }
        if (!defined($config->{'setup'}->{'mysql_cmd_line'})) {
        
            $config->{'status'}->{'DatabaseConnection'}->{'nimalarm_id'} = nimAlarm(
                $config->{'messages'}->{'DatabaseConnection'}->{'level'},
                $config->{'messages'}->{'DatabaseConnection'}->{'text'},
                $sub_sys,
                $config->{'messages'}->{'DatabaseConnection'}->{'supp_str'});
            nimLog(1, "Database connection alarm id : ".$config->{'status'}->{'DatabaseConnection'}->{'nimalarm_id'});
            return;
        }
        my @data = `$config->{'setup'}->{'mysql_cmd_line'} 2>/dev/null`;
        if (!@data) {
            $config->{'status'}->{'DatabaseConnection'}->{'nimalarm_id'} = nimAlarm(
                $config->{'messages'}->{'DatabaseConnection'}->{'level'},
                $config->{'messages'}->{'DatabaseConnection'}->{'text'},
                $sub_sys,
                $config->{'messages'}->{'DatabaseConnection'}->{'supp_str'});
            nimLog(1, "Database alarm id : ".$config->{'status'}->{'DatabaseConnection'}->{'nimalarm_id'});
            return;
        } else {
            nimLog(3, "Database connectivity alert clear");
            $config->{'status'}->{'DatabaseConnection'}->{'nimalarm_id'} = nimAlarm( 
                NIML_CLEAR, 
                'Database connection established',
                $sub_sys, 
                $config->{'messages'}->{'DatabaseConnection'}->{'supp_str'});
            nimLog(3, "Database clear id : ".$config->{'status'}->{'DatabaseConnection'}->{'nimalarm_id'});
        }
        nimLog(2, 'Returned '.scalar(@data).' lines from mysql query');
        my $slave_status = {};
        foreach my $line (@data) {
            my ($key, $value) = $line =~ /^\s*(\S+):\s(\S*)$/;
            if (!defined($key) || !defined($value)) { next; }
            $slave_status->{$key} = $value;
        }
        if ($slave_status->{'Slave_IO_Running'} =~ /no/i) {
            $config->{'status'}->{'Slave_IO_Running'}->{'samples'}++;
            $config->{'status'}->{'Slave_IO_Running'}->{'last'} = $slave_status->{'Slave_IO_Running'};
        
            if ($config->{'status'}->{'Slave_IO_Running'} >= $config->{'samples'}) {
                nimLog(1, "Alerting Slave_IO_Running status");
            
                $config->{'status'}->{'Slave_IO_Running'}->{'nimalarm_id'} = nimAlarm(
                    $config->{'messages'}->{'Slave_IO_Running'}->{'level'},
                    $config->{'messages'}->{'Slave_IO_Running'}->{'text'}." ($config->{'status'}->{'Slave_IO_Running'}->{'samples'} samples) ",
                    $sub_sys,
                    $config->{'messages'}->{'Slave_IO_Running'}->{'supp_str'});
                nimLog(1, "Slave IO Running alarm id: ".$config->{'status'}->{'Slave_IO_Running'}->{'nimalarm_id'});
            }

        } elsif ($slave_status->{'Slave_IO_Running'} =~ /yes/i) {
            nimLog(3, 'Clearing Slave_IO_Running alert status');
        
            $config->{'status'}->{'Slave_IO_Running'}->{'samples'} = 0;
            $config->{'status'}->{'Slave_IO_Running'}->{'last'} = $slave_status->{'Slave_IO_Running'};
        
            $config->{'status'}->{'Slave_IO_Running'}->{'nimalarm_id'} = nimAlarm(
                NIML_CLEAR, 
                'Slave_IO_Running confirmed', 
                $sub_sys,
                $config->{'messages'}->{'Slave_IO_Running'}->{'supp_str'});
            nimLog(3, "Slave SQL Running clear id: ".$config->{'status'}->{'Slave_IO_Running'}->{'nimalarm_id'});
        
        } else {
            nimLog(1, "Invalid value detected in 'Slave_IO_Running' : ($slave_status->{'Slave_IO_Running'})");
        }
        if ($slave_status->{'Slave_SQL_Running'} =~ /no/i) {
            nimLog(3, 'Incrementing Slave_SQL_Running sample count');
            $config->{'status'}->{'Slave_SQL_Running'}->{'samples'}++;
            $config->{'status'}->{'Slave_SQL_Running'}->{'last'} = $slave_status->{'Slave_SQL_Running'};
            if ($config->{'status'}->{'Slave_SQL_Running'} >= $config->{'samples'}) {
                nimLog(2, "Alerting Slave_SQL_Running status");
                $config->{'status'}->{'Slave_SQL_Running'}->{'nimalarm_id'} = nimAlarm(
                    $config->{'messages'}->{'Slave_SQL_Running'}->{'level'},
                    $config->{'messages'}->{'Slave_SQL_Running'}->{'text'}." ($config->{'status'}->{'Slave_SQL_Running'}->{'samples'} samples) ",
                    $sub_sys,
                    $config->{'messages'}->{'Slave_SQL_Running'}->{'supp_str'});
                nimLog(1, "Slave SQL Running alarm id: ".$config->{'status'}->{'Slave_SQL_Running'}->{'nimalarm_id'});
            }
        } elsif ($slave_status->{'Slave_SQL_Running'} =~ /yes/i) {
            nimLog(3, 'Clearing Slave_SQL_Running alert status');
            $config->{'status'}->{'Slave_SQL_Running'}->{'samples'} = 0;
            $config->{'status'}->{'Slave_SQL_Running'}->{'last'} = $slave_status->{'Slave_SQL_Running'};
            $config->{'status'}->{'Slave_SQL_Running'}->{'nimalarm_id'} = nimAlarm(
                NIML_CLEAR, 
                "Slave_SQL_Running is running", 
                $sub_sys, 
                $config->{'messages'}->{'Slave_SQL_Running'}->{'supp_str'});
            nimLog(3, "Slave SQL Running clear id: ".$config->{'status'}->{'Slave_SQL_Running'}->{'nimalarm_id'});
        } else {
            nimLog(1, "Invalid value detected in 'Slave_SQL_Running' : ($slave_status->{'Slave_SQL_Running'})");
        }
        if ($slave_status->{'Seconds_Behind_Master'} eq 'NULL') {
            return;
        }
        if ($slave_status->{'Seconds_Behind_Master'} >= $config->{'setup'}->{'WARN'}) {
            $config->{'status'}->{'Seconds_Behind_Master'}->{'samples'}++;
            $config->{'status'}->{'Seconds_Behind_Master'}->{'last'} = $slave_status->{'Seconds_Behind_Master'};
            if ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($slave_status->{'Seconds_Behind_Master'} >= $config->{'setup'}->{'CRITICAL'}) {
                    nimLog(1, "Warning alert on 'Seconds_Behind_Master' ($slave_status->{'Seconds_Behind_Master'})");
                    my $alert_string = $config->{'messages'}->{'SecondBehindCrit'}->{'text'},;
                    $alert_string =~ s/%SEC_BEHIND%/$slave_status->{'Seconds_Behind_Master'}/e;
                    $alert_string .= " ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} samples)";
                    $config->{'status'}->{'Seconds_Behind_Master'}->{'nimalarm_id'} = nimAlarm(
                        $config->{'messages'}->{'SecondBehindCrit'}->{'level'},
                        $alert_string,
                        $sub_sys,
                        $config->{'messages'}->{'SecondBehindCrit'}->{'supp_str'});
                    nimLog(1, "Seconds Behind Master warning alarm id : ".$config->{'status'}->{'Seconds_Behind_Master'}->{'nimalarm_id'});
                } else {
                    nimLog(1, "Critical alert on 'Seconds_Behind_Master' ($slave_status->{'Seconds_Behind_Master'})");
                    my $alert_string = $config->{'messages'}->{'SecondBehindWarn'}->{'text'};
                    $alert_string =~ s/%SEC_BEHIND%/$slave_status->{'Seconds_Behind_Master'}/e;
                    $alert_string .= " ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} samples)";
                    $config->{'status'}->{'Seconds_Behind_Master'}->{'nimalarm_id'} = nimAlarm(
                        $config->{'messages'}->{'SecondBehindWarn'}->{'level'},
                        $alert_string,
                        $sub_sys,
                        $config->{'messages'}->{'SecondBehindWarn'}->{'supp_str'});
                    nimLog(1, "Seconds Behind Master critical alarm id : ".$config->{'status'}->{'Seconds_Behind_Master'}->{'nimalarm_id'});
                }
            }
        } else {
            $config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} = 0;
            $config->{'status'}->{'Seconds_Behind_Master'}->{'last'} = $slave_status->{'Seconds_Behind_Master'};
            nimLog(3, "Clearing alert on 'Seconds_Behind_Master' ($slave_status->{'Seconds_Behind_Master'})");
            my $alert_string = $config->{'messages'}->{'SecondBehindWarn'}->{'text'};
            $alert_string =~ s/%SEC_BEHIND%/$slave_status->{'Seconds_Behind_Master'}/e;
            $alert_string .= " ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} samples)";
            $config->{'status'}->{'Seconds_Behind_Master'}->{'nimalarm_id'} = nimAlarm(
                NIML_CLEAR,
                $alert_string,
                $sub_sys,
                $config->{'messages'}->{'SecondBehindWarn'}->{'supp_str'});
            nimLog(3, "Seconds Behind Master clear id : ".$config->{'status'}->{'Seconds_Behind_Master'}->{'nimalarm_id'});
        }
    } else {
        nimLog(1, "Mysql NOT detected. Skipping.");
        return;
    }
    return;
}

sub startQoS {
    my $now    = shift || time();
    my $source = nimGetVarStr(NIMV_ROBOTNAME);
    nimQoSMessage( "OPENSTACK-PROBES", $source, $config->{'setup'}->{'hostname'}, $now, "Start Run", 0, $config->{'setup'}->{'interval'}, -1);
    return;
}

sub endQoS {
    my $now    = shift || time();
    my $source = nimGetVarStr(NIMV_ROBOTNAME);
    nimQoSMessage( "OPENSTACK-PROBES", $source, $config->{'setup'}->{'hostname'}, $now, "Run Complete", 0, $config->{'setup'}->{'interval'}, -1);
    return;
}

sub test_exec_line {
    my ($_exec_line) = @_;
    
    if (!defined($_exec_line)) {
        return undef;
    }

    nimLog(3, "exec_line : ".$_exec_line);
    # the exec lines should be 0 for successful query - 1 for auth failure,
    # -1 for unspecific failures, and ($? >> 8) gives the code for other 
    # failures.
    my @_results = `$_exec_line`;
    if ($? != 0) {
        my $err_code = ($? >> 8);
        nimLog(2, "Exec failure ($err_code)");
        return $err_code;
    }

    # auth failures should be caught above, but check for empty results
    # anyway...
    if (!@_results) {
        return 1;
    }

    foreach my $line (@_results) {
        if ($line =~ "Slave_IO") {
            nimLog(3, "mysql query succeeded");
            return 0;
        }
    }
    return 1;
}

# Determine the mysql execution syntax
#
# - this works by taking the available auth/parms until we find a combo
#   that completes successfully.  Finish on first success.
#
sub initialize_mysql_exec {

    if (!defined($config->{'setup'}->{'mysql_exec'}) || ($config->{'setup'}->{'mysql_exec'} eq '')) {
        my @_exec;
        chomp(@_exec = `which mysql 2>/dev/null `);
        if (!@_exec) {
            nimLog(1, 'Cannot locate the executable mysql');
            $config->{'status'}->{'MysqlClient'}->{'nimalarm_id'} = nimAlarm( $config->{'messages'}->{'MysqlClient'}->{'level'}, $config->{'messages'}->{'MysqlClient'}->{'text'}, $sub_sys, 
                $config->{'messages'}->{'MysqlClient'}->{'supp_str'});
                
            $config->{'setup'}->{'mysql_exec'} = undef;
            nimLog(1, "Mysql execution alarm id : ".$config->{'status'}->{'MysqlClient'}->{'nimalarm_id'});
            return undef;
        } else {
            my $_exec_path = $_exec[0];
            nimLog(2, "Located mysql executable: '$_exec_path'");
            $config->{'setup'}->{'mysql_exec'} = $_exec_path;
            
            $config->{'status'}->{'MysqlClient'}->{'nimalarm_id'} = nimAlarm(
                NIML_CLEAR,
                $config->{'messages'}->{'MysqlClient'}->{'text'},
                $sub_sys, 
                $config->{'messages'}->{'MysqlClient'}->{'supp_str'});
            nimLog(3, "Mysql execution clear id : ".$config->{'status'}->{'MysqlClient'}->{'nimalarm_id'});
        }
    }
    
    # save some typing
    my $_query = ' -E -e "SHOW SLAVE STATUS"';
    
    # setup the possible params - they're not always all necessary, but it's 
    # best to use the fewest parameters necessary

    # numbers are appended to the keys to preserve order in the loop below - it's a hack
    my %_params = (
        '1default'  => (defined($config->{'setup'}->{'mysql_defaults_file'}) && ($config->{'setup'}->{'mysql_defaults_file'} ne '')) ? "--defaults-file=$config->{'setup'}->{'mysql_defaults_file'}" : undef,
        '2username' => (defined($config->{'setup'}->{'username'})            && ($config->{'setup'}->{'username'} ne ''))            ? "-u $config->{'setup'}->{'username'}" : undef,
        '3password' => (defined($config->{'setup'}->{'password'})            && ($config->{'setup'}->{'password'} ne ''))            ? "-p$config->{'setup'}->{'password'}"  : undef,
        '4hostname' => (defined($config->{'setup'}->{'hostname'})            && ($config->{'setup'}->{'hostname'} ne ''))            ? "-h $config->{'setup'}->{'hostname'}" : undef,
        '5port'     => (defined($config->{'setup'}->{'port'})                && ($config->{'setup'}->{'port'} ne ''))                ? "-P $config->{'setup'}->{'port'}"     : undef
    );
    
    foreach my $key (keys(%_params)) {
        if (!defined($_params{$key})) {
            delete($_params{$key});
        }
    }
    
    my $loops = 2**(scalar(keys(%_params)));
    for (my $i = 0; $i < $loops; $i++) {
        nimLog(4, "exec iteration $i");
        my $cmd_line = "$config->{'setup'}->{'mysql_exec'}";

        my $shift = 0;
        foreach my $key (sort keys(%_params)) {
            if ((1 << $shift) & $i) {
                if (defined($_params{$key}) && ($_params{$key} ne '')) { # redundant, but it's best to check - we can probably get rid of this
                    $cmd_line .= " $_params{$key}";
                }
            }
            $shift++;
        }
        $cmd_line .= $_query;
        if (test_exec_line($cmd_line) == 0) {
            $config->{'setup'}->{'mysql_cmd_line'} = $cmd_line;
            return 1;
        }        
    }
    return undef;
}

sub readConfig {
    nimQoSDefinition( 'OPENSTACK-PROBES', 'OPENSTACK', 'Health Check Info For RPC Environment', 'Seconds', 's', 0, 0);
    nimLog(1, "'$prgname' : Reading Config File");
    $config       = Nimbus::CFG->new("$prgname.cfg");    
    my $loglevel  = $options{'d'} || $config->{'setup'}->{'loglevel'} || 0;
    my $logfile   = $options{'l'} || $config->{'setup'}->{'logfile'} || $prgname.'.log';
    nimLogSet($logfile, $prgname, $loglevel, 0);
    if (!defined($config->{'setup'}->{'interval'})) { $config->{'setup'}->{'interval'} = 300; }
    if (!defined($config->{'setup'}->{'samples'})) { $config->{'setup'}->{'samples'} = 3; }
    if (!defined($config->{'setup'}->{'CRITICAL'})) { $config->{'setup'}->{'CRITICAL'} = 600; }
    if (!defined($config->{'setup'}->{'WARN'})) { $config->{'setup'}->{'WARN'} = 300; }
    if (!defined($config->{'setup'}->{'mysql_defaults_file'}) || ($config->{'setup'}->{'mysql_defaults_file'} eq '')) {
        if ( -e '/root/.my.cnf') { $config->{'setup'}->{'mysql_defaults_file'} = '/root/.my.cnf'; }
    } else {
        if (!( -e $config->{'setup'}->{'mysql_defaults_file'})) { 
            $config->{'setup'}->{'mysql_defaults_file'} = undef; 
        } else {
            nimLog(1, "Defaults file '$config->{setup}->{mysql_defaults_file} not found; ignoring");
        }
    }
}

sub ctrlc {
    exit;
}

getopts( "d:l:i:", \%options );
$SIG{INT} = \&ctrlc;
readConfig();
$config->{'status'}->{'next_run'} = time(); 
$config->{'status'}->{'Slave_IO_Running'}->{'last'} = 0; 
$config->{'status'}->{'Slave_IO_Running'}->{'samples'} = 0; 
$config->{'status'}->{'Slave_SQL_Running'}->{'last'} = 0; 
$config->{'status'}->{'Slave_SQL_Running'}->{'samples'} = 0; 
$config->{'status'}->{'Seconds_Behind_Master'}->{'last'} = 0; 
$config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} = 0; 
$config->{'messages'}->{'MysqlClient'}->{'supp_str'} = nimSuppToStr(0, 0, 0, "$prgname/noclient"); 
$config->{'messages'}->{'Slave_IO_Running'}->{'supp_str'} = nimSuppToStr(0, 0, 0, "$prgname/slave_IO"); 
$config->{'messages'}->{'Slave_SQL_Running'}->{'supp_str'} = nimSuppToStr(0, 0, 0, "$prgname/slave_SQL"); 
$config->{'messages'}->{'SecondBehindWarn'}->{'supp_str'} = nimSuppToStr(0, 0, 0, "$prgname/secs_behind"); 
$config->{'messages'}->{'SecondBehindCrit'}->{'supp_str'} = nimSuppToStr(0, 0, 0, "$prgname/secs_behind"); 
$config->{'messages'}->{'DatabaseConnection'}->{'supp_str'} = nimSuppToStr(0, 0, 0, "$prgname/DatabaseConnection"); 
$config->{'messages'}->{'RabbitConnection'}->{'supp_str'} = nimSuppToStr(0, 0, 0, "$prgname/RabbitConnection"); 
my $sess = Nimbus::Session->new("$prgname");
$sess->setInfo($version, "Rackspace IT Hosting");

if ($sess->server(NIMPORT_ANY, \&timeout, \&readConfig) == NIME_OK) {
    nimLog( 1, "server session is created" );
} else {
    nimLog( 0, "unable to create server session" );
    exit(1);
}

$sess->dispatch();
nimLog(0, "Received STOP, terminating program");
nimLog(0, "Exiting program" );
exit;
