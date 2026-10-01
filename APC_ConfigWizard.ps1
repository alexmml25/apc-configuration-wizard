#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    APC Configuration Deployment Wizard - GUI Entry Point
.DESCRIPTION
    Step-by-step WPF wizard that configures the APC system (D01555607) after installation and
    drafts the D01555624 Configuration Verification Checklist.
    Pick a configuration type, sign in, fill in the pages that type needs, review, run, then
    generate the draft checklist. Modules 01-13 run automatically. CHMI steps (11) include a manual pause.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RootDir      = $PSScriptRoot
$Script:ModulesDir   = Join-Path $Script:RootDir 'modules'
$Script:ManifestPath = Join-Path $Script:RootDir 'APC_ConfigManifest.json'
$Script:StateFile    = 'C:\APC_Config\.config_state.json'
$Script:LogDir       = 'C:\APC_Config\Logs'

function Get-Manifest {
    if (-not (Test-Path $Script:ManifestPath)) {
        [System.Windows.MessageBox]::Show("Manifest not found:`n$Script:ManifestPath", "APC Wizard Error", "OK", "Error") | Out-Null
        exit 1
    }
    return Get-Content $Script:ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$manifest = Get-Manifest
. (Join-Path $Script:ModulesDir 'Common.ps1')
. (Join-Path $Script:ModulesDir 'ABB800xA.ps1')
$Script:RunManifest = $manifest   # replaced by the sandbox copy in test mode
$Script:TestMode    = $false
$Script:SkipSteps   = @()
$Script:RunModeName = 'full run'

# Step definitions
$StepDefs = @(
    @{ Index =  1; Name = 'Site DB Fetch';                  File = '01-SiteDBFetch.ps1';      Fn = 'Invoke-SiteDBFetch'       },
    @{ Index =  2; Name = 'TimescaleDB Setup';              File = '02-TimescaleDB.ps1';      Fn = 'Invoke-TimescaleDBSetup'  },
    @{ Index =  3; Name = 'SINC Folder Structure';          File = '03-SINCFolders.ps1';      Fn = 'Invoke-SINCFolders'       },
    @{ Index =  4; Name = 'deviceWise Base Platform';       File = '04-DeviceWiseBase.ps1';   Fn = 'Invoke-DeviceWiseBase'    },
    @{ Index =  5; Name = 'deviceWise CHMI Integration';    File = '05-DeviceWiseCHMI.ps1';   Fn = 'Invoke-DeviceWiseCHMI'    },
    @{ Index =  6; Name = 'deviceWise SINC Integration';    File = '06-DeviceWiseSINC.ps1';   Fn = 'Invoke-DeviceWiseSINC'    },
    @{ Index =  7; Name = 'deviceWise CNCnetPDM Integrate'; File = '07-DeviceWiseCNCPDM.ps1'; Fn = 'Invoke-DeviceWiseCNCPDM'  },
    @{ Index =  8; Name = 'CNCnetPDM Configuration';        File = '08-CNCnetPDM.ps1';        Fn = 'Invoke-CNCnetPDM'   },
    @{ Index =  9; Name = 'DOC XML Configuration';          File = '09-DOCConfig.ps1';        Fn = 'Invoke-DOCConfig'         },
    @{ Index = 10; Name = 'Data Applications Config';       File = '10-DataApps.ps1';         Fn = 'Invoke-DataApps'    },
    @{ Index = 11; Name = 'CHMI / APC UI OPC UA';           File = '11-CHMI.ps1';             Fn = 'Invoke-CHMI'        },
    @{ Index = 12; Name = 'Application Backup';             File = '12-Backup.ps1';           Fn = 'Invoke-Backup' },
    @{ Index = 13; Name = 'Verification & Report';          File = '13-Verification.ps1';     Fn = 'Invoke-Verification'}
)

# Configuration types = the "Reason for Configuration" options of D01555624 (ReasonIndex = checkbox row).
# Verification replaces "Other" in the wizard: a read-only check that ticks "Other" in the draft.
# Folder = prefix of the run's own folder, C:\APC_Config\<Folder>_<yyyyMMdd-HHmmss> (Logs, Backups, Reports inside).
$Script:ConfigTypes = [ordered]@{
    initial   = @{ Name = 'Initial System Configuration';   ReasonIndex = 0; Folder = 'InitialConfiguration' }
    restore   = @{ Name = 'Configuration Restore';          ReasonIndex = 1; Folder = 'ConfigurationRestore' }
    component = @{ Name = 'System Component Configuration'; ReasonIndex = 2; Folder = 'ComponentConfiguration' }
    update    = @{ Name = 'Configuration Update';           ReasonIndex = 3; Folder = 'ConfigurationUpdate' }
    sysupdate = @{ Name = 'System Update / Import';         ReasonIndex = 4; Folder = 'SystemUpdate' }
    verify    = @{ Name = 'Verification';                   ReasonIndex = 5; Folder = 'Verification' }
}
$Script:VerifyReasonOther = 'Verification only (no changes)'
$Script:Dot = [string][char]0x00B7   # middle dot; kept out of the source so Windows PowerShell 5.1 reads the file as plain ASCII

# Components offered for System Component Configuration / Configuration Update, and the steps each runs
$Script:Components = [ordered]@{
    tsdb = @{ Label = 'TimescaleDB';                                                   Steps = @(2) }
    sinc = @{ Label = 'SINC folders';                                                  Steps = @(3) }
    dw   = @{ Label = 'deviceWise';                                                    Steps = @(4, 5, 6, 7) }
    cnc  = @{ Label = 'CNCnetPDM';                                                     Steps = @(8) }
    doc  = @{ Label = 'DOC';                                                           Steps = @(9) }
    da   = @{ Label = 'Data applications (File Manager, Data Collector, Data Analyzer)'; Steps = @(10) }
    chmi = @{ Label = 'CHMI / APC UI';                                                 Steps = @(11) }
}

$Script:PageLabels = [ordered]@{
    type       = 'Configuration type'
    signin     = 'Sign in & site'
    scope      = 'Components'
    machines   = 'Machines & DOC'
    components = 'SINC & CNCnetPDM'
    dataapps   = 'Data applications'
    chmi       = 'CHMI (800xA)'
    review     = 'Review & run'
    run        = 'Run'
    verify     = 'Verification'
}
$Script:PagePanels = @{
    type = 'PageType'; signin = 'PageSignin'; scope = 'PageScope'; machines = 'PageMachines'; components = 'PageComponents'
    dataapps = 'PageDataApps'; chmi = 'PageCHMI'; review = 'PageReview'; run = 'PageRun'; verify = 'PageVerify'
}

$xamlText = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="APC Configuration Deployment Wizard"
    Width="1000" Height="720"
    MinWidth="860" MinHeight="600"
    WindowStartupLocation="CenterScreen"
    FontFamily="Segoe UI" FontSize="13"
    Background="#F8FAFC">

  <Window.Resources>
    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Padding"         Value="16,8"/>
      <Setter Property="FontSize"        Value="13"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="BorderBrush"     Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource NavBtn}">
      <Setter Property="Background" Value="#4361EE"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#3451D1"/></Trigger>
        <Trigger Property="IsEnabled"   Value="False"><Setter Property="Background" Value="#94A3B8"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="SecondaryBtn" TargetType="Button" BasedOn="{StaticResource NavBtn}">
      <Setter Property="Background"      Value="#FFFFFF"/>
      <Setter Property="Foreground"      Value="#334155"/>
      <Setter Property="BorderBrush"     Value="#CBD5E1"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F1F5F9"/></Trigger>
        <Trigger Property="IsEnabled"   Value="False"><Setter Property="Foreground" Value="#CBD5E1"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="NavItemBtn" TargetType="Button">
      <Setter Property="Background"   Value="Transparent"/>
      <Setter Property="Padding"      Value="8"/>
      <Setter Property="Margin"       Value="0,0,0,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TypeCard" TargetType="RadioButton">
      <Setter Property="GroupName" Value="ConfigType"/>
      <Setter Property="Cursor"    Value="Hand"/>
      <Setter Property="Margin"    Value="0,0,12,12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="TcBd" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="8" Padding="14">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid Width="16" Height="16" Margin="0,2,10,0" VerticalAlignment="Top">
                  <Ellipse x:Name="TcRing" Stroke="#94A3B8" StrokeThickness="1.5" Fill="White"/>
                  <Ellipse x:Name="TcDot" Width="8" Height="8" Fill="#4361EE" Visibility="Collapsed"/>
                </Grid>
                <ContentPresenter Grid.Column="1"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TcBd" Property="BorderBrush" Value="#94A3B8"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="TcBd"   Property="BorderBrush" Value="#4361EE"/>
                <Setter TargetName="TcBd"   Property="Background"  Value="#EEF2FF"/>
                <Setter TargetName="TcRing" Property="Stroke"      Value="#4361EE"/>
                <Setter TargetName="TcDot"  Property="Visibility"  Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="TcBd" Property="Opacity" Value="0.55"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SegBtn" TargetType="RadioButton">
      <Setter Property="GroupName" Value="DocCount"/>
      <Setter Property="Cursor"    Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="SegBd" Width="44" Height="30" Background="#FFFFFF">
              <ContentPresenter x:Name="SegCp" HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.FontWeight="SemiBold" TextElement.Foreground="#334155"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="SegBd" Property="Background" Value="#4361EE"/>
                <Setter TargetName="SegCp" Property="TextElement.Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LogBox" TargetType="TextBox">
      <Setter Property="FontFamily"                    Value="Consolas"/>
      <Setter Property="FontSize"                      Value="11"/>
      <Setter Property="IsReadOnly"                    Value="True"/>
      <Setter Property="TextWrapping"                  Value="NoWrap"/>
      <Setter Property="VerticalScrollBarVisibility"   Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="Background"                    Value="#1C2136"/>
      <Setter Property="Foreground"                    Value="#CBD5E1"/>
      <Setter Property="BorderThickness"               Value="0"/>
      <Setter Property="Padding"                       Value="10"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background"      Value="#FFFFFF"/>
      <Setter Property="BorderBrush"     Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius"    Value="8"/>
      <Setter Property="Padding"         Value="16"/>
      <Setter Property="Margin"          Value="0,0,0,16"/>
    </Style>
    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontSize"   Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#1C2136"/>
      <Setter Property="Margin"     Value="0,0,0,4"/>
    </Style>
    <Style x:Key="PageHint" TargetType="TextBlock">
      <Setter Property="FontSize"     Value="12"/>
      <Setter Property="Foreground"   Value="#64748B"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin"       Value="0,0,0,16"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#1C2136"/>
      <Setter Property="Margin"     Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground"        Value="#475569"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin"            Value="0,0,12,10"/>
    </Style>
    <Style x:Key="ColHead" TargetType="TextBlock">
      <Setter Property="FontSize"   Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="Margin"     Value="0,0,0,8"/>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Padding"          Value="6,5"/>
      <Setter Property="Margin"           Value="0,0,0,10"/>
      <Setter Property="BorderBrush"      Value="#CBD5E1"/>
      <Setter Property="BorderThickness"  Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Pwd" TargetType="PasswordBox">
      <Setter Property="Padding"          Value="6,5"/>
      <Setter Property="Margin"           Value="0,0,0,10"/>
      <Setter Property="BorderBrush"      Value="#CBD5E1"/>
      <Setter Property="BorderThickness"  Value="1"/>
    </Style>
    <Style x:Key="Combo" TargetType="ComboBox">
      <Setter Property="Padding"     Value="6,5"/>
      <Setter Property="Margin"      Value="0,0,0,10"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="56"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="64"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#F0F0F0" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Image x:Name="ImgLogo" Height="36" MaxWidth="150" Stretch="Uniform" Margin="0,0,24,0" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Text="APC Configuration Deployment Wizard" FontSize="18" FontWeight="SemiBold"
                   Foreground="Black" VerticalAlignment="Center"/>
        <Border Grid.Column="2" Background="#FFFFFF" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="12"
                Padding="10,3" VerticalAlignment="Center">
          <TextBlock x:Name="TxtTypeChip" FontSize="12" Foreground="#334155"/>
        </Border>
        <Image x:Name="ImgAppIcon" Grid.Column="3" Width="44" Height="44" Stretch="Uniform" Margin="16,0,0,0" VerticalAlignment="Center"
               RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="True"/>
      </Grid>
    </Border>

    <!-- Body: step list + page -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="0,0,1,0" Padding="12,20">
        <StackPanel x:Name="NavList"/>
      </Border>

      <ScrollViewer Grid.Column="1" x:Name="MainScroller" VerticalScrollBarVisibility="Auto">
        <Grid Margin="32,24,32,24">

          <!-- ===== CONFIGURATION TYPE ===== -->
          <StackPanel x:Name="PageType">
            <TextBlock Text="What are you configuring?" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="Pick the reason for this configuration. It decides which steps follow and is ticked under Reason for Configuration in the D01555624 checklist."/>
            <UniformGrid Columns="2" Margin="0,0,-12,0">
              <RadioButton x:Name="RbType_initial" Style="{StaticResource TypeCard}" IsChecked="True">
                <StackPanel>
                  <TextBlock Text="Initial System Configuration" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Establishment of APC system configuration following installation." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="All 13 steps" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_restore" Style="{StaticResource TypeCard}" IsEnabled="False">
                <StackPanel>
                  <TextBlock Text="Configuration Restore" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Restoration of APC configuration from an approved backup." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Not available yet" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_component" Style="{StaticResource TypeCard}">
                <StackPanel>
                  <TextBlock Text="System Component Configuration" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Configuration or update of individual APC components (e.g., deviceWise, DA DOC, CNCnetPDM) without impacting the full system." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Pick the components" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_update" Style="{StaticResource TypeCard}">
                <StackPanel>
                  <TextBlock Text="Configuration Update" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Modification of existing APC configuration elements without full system restore or package deployment." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Pick the components" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_sysupdate" Style="{StaticResource TypeCard}" IsEnabled="False">
                <StackPanel>
                  <TextBlock Text="System Update / Import" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Deployment or import of approved configuration packages, including CHMI or APC interface updates." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Not available yet" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_verify" Style="{StaticResource TypeCard}">
                <StackPanel>
                  <TextBlock Text="Verification" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Check that the APC system is configured and working, without changing anything. Useful for troubleshooting." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Read-only - drafts the checklist" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
            </UniformGrid>
          </StackPanel>

          <!-- ===== SIGN IN & SITE ===== -->
          <StackPanel x:Name="PageSignin" Visibility="Collapsed">
            <TextBlock Text="Sign in and site" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="Your domain login is checked, then the machines are loaded from the site's Site DB. The Site DB connection is filled in from the site."/>
            <Border Style="{StaticResource Card}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="Username" Style="{StaticResource Label}"/>
                <TextBox   x:Name="TxtUsername" Grid.Row="0" Grid.Column="1" Style="{StaticResource Input}"/>
                <TextBlock Grid.Row="1" Text="Password" Style="{StaticResource Label}"/>
                <PasswordBox x:Name="PwdUserAccount" Grid.Row="1" Grid.Column="1" Style="{StaticResource Pwd}"/>
                <TextBlock Grid.Row="2" Text="Site" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                <ComboBox  x:Name="CmbSiteCode" Grid.Row="2" Grid.Column="1" Style="{StaticResource Combo}" Width="160" HorizontalAlignment="Left" Margin="0"/>
              </Grid>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Site Database" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Hostname" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtSiteDBHost" Grid.Row="0" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="1" Text="Username" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtSiteDBUser" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="2" Text="Password" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                  <PasswordBox x:Name="PwdSiteDB" Grid.Row="2" Grid.Column="1" Style="{StaticResource Pwd}" Margin="0"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border Margin="0,0,0,16" Background="#FFFBEB" BorderBrush="#FDE68A" BorderThickness="1" CornerRadius="8" Padding="16">
              <StackPanel>
                <TextBlock Text="Component passwords" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,2"/>
                <TextBlock FontSize="11" Foreground="#92400E" TextWrapping="Wrap" Margin="0,0,0,12"
                           Text="Needed only when TimescaleDB (step 2) or deviceWise (step 4) runs. In memory only - never written to disk or logs."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="apcuser (local)" Style="{StaticResource Label}"
                             ToolTip="Password for the local TimescaleDB apcuser role created in Step 2."/>
                  <PasswordBox x:Name="PwdAPCUser" Grid.Row="0" Grid.Column="1" Style="{StaticResource Pwd}"/>
                  <TextBlock Grid.Row="1" Text="MedtronicSU" Style="{StaticResource Label}" Margin="0,0,12,0"
                             ToolTip="Password for the MedtronicSU OPC UA user created in deviceWise Gateway (Step 4)"/>
                  <PasswordBox x:Name="PwdMedtronicSU" Grid.Row="1" Grid.Column="1" Style="{StaticResource Pwd}" Margin="0"/>
                </Grid>
              </StackPanel>
            </Border>
            <TextBlock x:Name="TxtProceedStatus" FontSize="12" Foreground="#64748B" TextWrapping="Wrap"/>
          </StackPanel>

          <!-- ===== COMPONENTS (component configuration / update) ===== -->
          <StackPanel x:Name="PageScope" Visibility="Collapsed">
            <TextBlock Text="Which components?" Style="{StaticResource PageTitle}"/>
            <TextBlock x:Name="TxtScopeHint" Style="{StaticResource PageHint}"
                       Text="Only the selected components are configured; everything else is left as it is."/>
            <Border Style="{StaticResource Card}" Padding="16,6">
              <StackPanel>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,0,0,1" Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Step 2" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_tsdb" Content="TimescaleDB" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,0,0,1" Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Step 3" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_sinc" Content="SINC folders" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,0,0,1" Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Steps 4-7" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_dw" Content="deviceWise" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,0,0,1" Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Step 8" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_cnc" Content="CNCnetPDM" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,0,0,1" Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Step 9" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_doc" Content="DOC" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,0,0,1" Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Step 10" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_da" Content="Data applications (File Manager, Data Collector, Data Analyzer)" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
                <Border Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Step 11" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_chmi" Content="CHMI / APC UI" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
              </StackPanel>
            </Border>
            <TextBlock Style="{StaticResource PageHint}" Text="Step 1 (Site DB fetch), Step 12 (backup) and Step 13 (verification) always run."/>
          </StackPanel>

          <!-- ===== MACHINES & DOC ===== -->
          <StackPanel x:Name="PageMachines" Visibility="Collapsed">
            <TextBlock Text="Machines and DOC instances" Style="{StaticResource PageTitle}"/>
            <TextBlock x:Name="TxtMachineCount" Style="{StaticResource PageHint}"
                       Text="DOC n = CNC n; only assigned machines are configured."/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,16">
              <TextBlock Text="DOC instances" Style="{StaticResource Label}" Margin="0,0,12,0"/>
              <Border BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="6" ClipToBounds="True">
                <StackPanel Orientation="Horizontal">
                  <RadioButton x:Name="RbDoc1" Style="{StaticResource SegBtn}" Content="1"/>
                  <Border Width="1" Background="#CBD5E1"/>
                  <RadioButton x:Name="RbDoc2" Style="{StaticResource SegBtn}" Content="2"/>
                  <Border Width="1" Background="#CBD5E1"/>
                  <RadioButton x:Name="RbDoc3" Style="{StaticResource SegBtn}" Content="3" IsChecked="True"/>
                </StackPanel>
              </Border>
            </StackPanel>
            <Border Style="{StaticResource Card}" Padding="16,12">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="110"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="CNC"       Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="1" Text="MACHINE"   Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="2" Text="FAMILY"    Style="{StaticResource ColHead}" Margin="12,0,0,8"/>
                  <TextBlock Grid.Column="3" Text="DEVICE NR" Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="4" Text="DLL"       Style="{StaticResource ColHead}"/>
                </Grid>
                <Grid x:Name="GridDOCRow1">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="110"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC1" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbDOCMachine1" Grid.Column="1" Style="{StaticResource Combo}"/>
                  <TextBlock x:Name="TxtDOCFam1" Grid.Column="2" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="12,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDev1" Grid.Column="3" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDll1" Grid.Column="4" FontFamily="Consolas" FontSize="12" VerticalAlignment="Center" Margin="0,0,0,10"/>
                </Grid>
                <Grid x:Name="GridDOCRow2">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="110"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC2" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbDOCMachine2" Grid.Column="1" Style="{StaticResource Combo}"/>
                  <TextBlock x:Name="TxtDOCFam2" Grid.Column="2" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="12,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDev2" Grid.Column="3" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDll2" Grid.Column="4" FontFamily="Consolas" FontSize="12" VerticalAlignment="Center" Margin="0,0,0,10"/>
                </Grid>
                <Grid x:Name="GridDOCRow3">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="110"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC3" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbDOCMachine3" Grid.Column="1" Style="{StaticResource Combo}"/>
                  <TextBlock x:Name="TxtDOCFam3" Grid.Column="2" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="12,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDev3" Grid.Column="3" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDll3" Grid.Column="4" FontFamily="Consolas" FontSize="12" VerticalAlignment="Center" Margin="0,0,0,10"/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ===== SINC & CNCnetPDM ===== -->
          <StackPanel x:Name="PageComponents" Visibility="Collapsed">
            <TextBlock Text="SINC and CNCnetPDM" Style="{StaticResource PageTitle}" Margin="0,0,0,16"/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="SINC" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Alert email" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                  <TextBox x:Name="TxtSINCEmail" Grid.Column="1" Style="{StaticResource Input}" Margin="0"
                           ToolTip="Semicolon-separated email addresses for SINC alerts"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="CNCnetPDM" Style="{StaticResource CardTitle}"/>
                <CheckBox x:Name="ChkDefaultLicense" Content="Use default perpetual license" IsChecked="True" Margin="140,0,0,10"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock Text="License key" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                  <TextBox x:Name="TxtLicense" Grid.Column="1" Style="{StaticResource Input}" Margin="0" FontFamily="Consolas" IsEnabled="False"
                           ToolTip="Written to CNCnetPDM.ini [GENERAL] License. Untick the box above to enter a different key."/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ===== DATA APPLICATIONS ===== -->
          <StackPanel x:Name="PageDataApps" Visibility="Collapsed">
            <TextBlock Text="Data applications" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="Tick the CNCs that use each instrument. Source = shared folder the instrument drops files into. Error path blank = local DoneError folder. Broadcast (MES) blank = NA."/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="Local data root" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtDataRoot" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas"
                       ToolTip="File Manager NewPath and Data Collector CheckPath root (one sub-folder per instrument)"/>
            </Grid>
            <Border Style="{StaticResource Card}" Padding="16,12,16,4">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="100"/><ColumnDefinition Width="64"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="INSTRUMENT"  Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="1" Text="QTY"         Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="2" Text="USED BY"     Style="{StaticResource ColHead}" Margin="12,0,0,8" MinWidth="190"/>
                  <TextBlock Grid.Column="3" Text="SOURCE PATH" Style="{StaticResource ColHead}"/>
                </Grid>
                <!--DATAAPPS_INSTRUMENTS-->
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ===== CHMI (800xA) ===== -->
          <StackPanel x:Name="PageCHMI" Visibility="Collapsed">
            <TextBlock Text="CHMI (800xA)" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="Written to the 800xA General Properties of each cell in Step 11. Values are pre-filled from 800xA; only changed values are written, and before/after values are logged."/>
            <Border Style="{StaticResource Card}" Padding="16,12,16,6">
              <StackPanel>
                <TextBlock Text="Verification trigger" Style="{StaticResource CardTitle}" Margin="0,0,0,2"/>
                <TextBlock Style="{StaticResource PageHint}" Margin="0,0,0,10" Text="Button = verification on button press only. Both = button press or shift change."/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="90"/><ColumnDefinition Width="170"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="CNC"     Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="1" Text="MACHINE" Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="2" Text="CELL"    Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="3" Text="CURRENT" Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="4" Text="SET TO"  Style="{StaticResource ColHead}"/>
                </Grid>
                <Grid x:Name="GridCHMIRow1">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="90"/><ColumnDefinition Width="170"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC1" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtCHMIMachine1" Grid.Column="1" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock Grid.Column="2" Text="Cell_1" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtCHMICurrent1" Grid.Column="3" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbCHMITrigger1" Grid.Column="4" Style="{StaticResource Combo}">
                    <ComboBoxItem Content="Button" Tag="False"/>
                    <ComboBoxItem Content="Both" Tag="True"/>
                  </ComboBox>
                </Grid>
                <Grid x:Name="GridCHMIRow2">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="90"/><ColumnDefinition Width="170"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC2" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtCHMIMachine2" Grid.Column="1" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock Grid.Column="2" Text="Cell_2" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtCHMICurrent2" Grid.Column="3" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbCHMITrigger2" Grid.Column="4" Style="{StaticResource Combo}">
                    <ComboBoxItem Content="Button" Tag="False"/>
                    <ComboBoxItem Content="Both" Tag="True"/>
                  </ComboBox>
                </Grid>
                <Grid x:Name="GridCHMIRow3">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="90"/><ColumnDefinition Width="170"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC3" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtCHMIMachine3" Grid.Column="1" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock Grid.Column="2" Text="Cell_3" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtCHMICurrent3" Grid.Column="3" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbCHMITrigger3" Grid.Column="4" Style="{StaticResource Combo}">
                    <ComboBoxItem Content="Button" Tag="False"/>
                    <ComboBoxItem Content="Both" Tag="True"/>
                  </ComboBox>
                </Grid>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,1,0,0" Padding="0,10,0,0">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="180"/><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock Text="First shift starts at" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="CmbShift1Hour" Grid.Column="1" Style="{StaticResource Combo}"/>
                    <TextBlock x:Name="TxtShiftHint" Grid.Column="2" FontSize="12" Foreground="#64748B" TextWrapping="Wrap" VerticalAlignment="Center" Margin="12,0,0,10"/>
                  </Grid>
                </Border>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Inspection CSV folders" Style="{StaticResource CardTitle}" Margin="0,0,0,2"/>
                <TextBlock Style="{StaticResource PageHint}" Margin="0,0,0,10" Text="Measurements &gt; Inspections GP, the same for every cell. Filled in from the local data root."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="180"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                  <TextBlock Text="BENCH sample CSV" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TxtCHMIBench" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas"/>
                  <TextBlock Grid.Row="1" Text="100% inspection CSV" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TxtCHMIPct" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas"/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ===== REVIEW & RUN ===== -->
          <StackPanel x:Name="PageReview" Visibility="Collapsed">
            <TextBlock Text="Review and run" Style="{StaticResource PageTitle}"/>
            <TextBlock x:Name="TxtReviewHint" Style="{StaticResource PageHint}" Text="Check the summary, choose how to run, then start."/>
            <Border Style="{StaticResource Card}" Padding="16,12">
              <StackPanel x:Name="PanelSummary"/>
            </Border>
            <Border x:Name="PanelRunMode" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Run mode" Style="{StaticResource CardTitle}"/>
                <RadioButton x:Name="RbModeReviewed" GroupName="RunMode" Margin="0,0,0,10">
                  <StackPanel Margin="4,0,0,0">
                    <TextBlock Text="Reviewed steps only" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtModeDescReviewed" FontSize="12" Foreground="#64748B" TextWrapping="Wrap"/>
                  </StackPanel>
                </RadioButton>
                <RadioButton x:Name="RbModeFull" GroupName="RunMode" Margin="0,0,0,10">
                  <StackPanel Margin="4,0,0,0">
                    <TextBlock Text="Full run" FontWeight="SemiBold"/>
                    <TextBlock FontSize="12" Foreground="#64748B" TextWrapping="Wrap" Text="Every selected step on the real system."/>
                  </StackPanel>
                </RadioButton>
                <RadioButton x:Name="RbModeTest" GroupName="RunMode">
                  <StackPanel Margin="4,0,0,0">
                    <TextBlock Text="Test mode" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtModeDescTest" FontSize="12" Foreground="#64748B" TextWrapping="Wrap"/>
                  </StackPanel>
                </RadioButton>
              </StackPanel>
            </Border>
            <Border x:Name="PanelReadOnly" Margin="0,0,0,16" Background="#F0FDF4" BorderBrush="#BBF7D0" BorderThickness="1" CornerRadius="8" Padding="16,12" Visibility="Collapsed">
              <TextBlock TextWrapping="Wrap" Foreground="#166534">
                <Bold>Read-only.</Bold> No configuration, service or database on this VM is changed; only the report and the draft checklist are saved, in this run's folder under C:\APC_Config. Use it to check an existing system or to troubleshoot.
              </TextBlock>
            </Border>
            <Border Style="{StaticResource Card}" Padding="16,12">
              <StackPanel>
                <TextBlock Text="Steps that will run" Style="{StaticResource CardTitle}" Margin="0,0,0,8"/>
                <WrapPanel x:Name="WrapRunSteps"/>
              </StackPanel>
            </Border>
            <Expander Header="Advanced (testing)" Foreground="#475569">
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <TextBlock Text="Start from step" Style="{StaticResource Label}" Margin="0,0,8,0"/>
                <ComboBox x:Name="CmbStartStep" Style="{StaticResource Combo}" Width="70" Margin="0">
                  <ComboBoxItem Content="1" IsSelected="True"/>
                  <ComboBoxItem Content="2"/>
                  <ComboBoxItem Content="3"/>
                  <ComboBoxItem Content="4"/>
                  <ComboBoxItem Content="5"/>
                  <ComboBoxItem Content="6"/>
                  <ComboBoxItem Content="7"/>
                  <ComboBoxItem Content="8"/>
                  <ComboBoxItem Content="9"/>
                  <ComboBoxItem Content="10"/>
                  <ComboBoxItem Content="11"/>
                  <ComboBoxItem Content="12"/>
                  <ComboBoxItem Content="13"/>
                </ComboBox>
                <TextBlock Text="(skip earlier steps - for testing only)" Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Expander>
          </StackPanel>

          <!-- ===== RUN ===== -->
          <StackPanel x:Name="PageRun" Visibility="Collapsed">
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="TxtRunTitle" Text="Running" Style="{StaticResource PageTitle}"/>
              <TextBlock x:Name="TxtProgressLabel" Grid.Column="1" Text="0 / 13 steps" FontSize="12" Foreground="#64748B" VerticalAlignment="Center"/>
            </Grid>
            <ProgressBar x:Name="BarOverall" Height="8" Minimum="0" Maximum="13" Value="0" Margin="0,0,0,12"
                         Foreground="#4361EE" Background="#E2E8F0" BorderThickness="0"/>
            <Border Style="{StaticResource Card}" Padding="14,4">
              <StackPanel>
                <!--STEP_ROWS-->
              </StackPanel>
            </Border>
            <Expander Header="Show log" Foreground="#4361EE">
              <TextBox x:Name="LogAll" Style="{StaticResource LogBox}" Height="220" Margin="0,8,0,0"/>
            </Expander>
          </StackPanel>

          <!-- ===== VERIFICATION (draft checklist) ===== -->
          <StackPanel x:Name="PageVerify" Visibility="Collapsed">
            <TextBlock Text="Verification" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="The wizard drafts the D01555624 Configuration Verification Checklist from the verification results. It does not approve it: review and QA sign it independently."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Verification results" Style="{StaticResource CardTitle}" Margin="0,0,0,2"/>
                <TextBlock x:Name="TxtVerifySummary" FontSize="12" Foreground="#64748B" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Checklist details" Style="{StaticResource CardTitle}"/>
                <Grid x:Name="PanelReason" Visibility="Collapsed" Margin="0,0,0,12">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Reason for configuration" Style="{StaticResource Label}" VerticalAlignment="Top"/>
                  <UniformGrid Grid.Column="1" Columns="2">
                    <RadioButton x:Name="RbReason0" GroupName="Reason" Content="Initial System Configuration"   Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason1" GroupName="Reason" Content="Configuration Restore"          Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason2" GroupName="Reason" Content="System Component Configuration" Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason3" GroupName="Reason" Content="Configuration Update"           Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason4" GroupName="Reason" Content="System Update"                  Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason5" GroupName="Reason" Content="Other: Verification only (no changes)" IsChecked="True" Margin="0,0,12,6"/>
                  </UniformGrid>
                </Grid>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Text="Related change record (Change ID)" Style="{StaticResource Label}" TextWrapping="Wrap"/>
                  <TextBox x:Name="TxtChangeID" Grid.Column="1" Style="{StaticResource Input}" Margin="0,0,0,4"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" FontSize="11" Foreground="#94A3B8"
                             Text="Required for restores, component changes, updates and system updates."/>
                </Grid>
              </StackPanel>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
              <Button x:Name="BtnGenerateReport" Style="{StaticResource PrimaryBtn}" Content="Generate draft checklist"/>
              <Button x:Name="BtnOpenReport" Style="{StaticResource SecondaryBtn}" Content="Open draft" Margin="8,0,0,0" Visibility="Collapsed"/>
              <TextBlock x:Name="TxtReportStatus" VerticalAlignment="Center" Margin="12,0,0,0" FontSize="12" Foreground="#64748B"/>
            </StackPanel>
            <TextBlock x:Name="TxtReportPath" Margin="0,0,0,10" Foreground="#166534" FontFamily="Consolas" FontSize="11"
                       Visibility="Collapsed" TextWrapping="Wrap"/>
            <Expander Header="Show log" Foreground="#4361EE">
              <TextBox x:Name="LogReport" Style="{StaticResource LogBox}" Height="180" Margin="0,8,0,0"/>
            </Expander>
          </StackPanel>

        </Grid>
      </ScrollViewer>
    </Grid>

    <!-- Footer: Back / Next -->
    <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="32,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtFooterStep" FontSize="12" Foreground="#64748B" VerticalAlignment="Center"/>
        <Button x:Name="BtnBack" Grid.Column="1" Style="{StaticResource SecondaryBtn}" Content="Back" Padding="18,9" FontWeight="SemiBold"/>
        <Button x:Name="BtnNext" Grid.Column="2" Style="{StaticResource PrimaryBtn}" Content="Next" Padding="22,9" Margin="12,0,0,0"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# Data Applications instrument rows (one block per manifest instrument type)
$instFrag = foreach ($inst in $manifest.DataApps.Instruments) {
    $t     = $inst.Type
    $qty   = (1..[int]$inst.MaxCount | ForEach-Object { "<ComboBoxItem Content=`"$_`"/>" }) -join ''
    $chks  = (1..3 | ForEach-Object { "<CheckBox x:Name=`"ChkInst_${t}_$_`" Content=`"CNC$_`" VerticalAlignment=`"Center`" Margin=`"0,0,12,0`"/>" }) -join ''
    @"
                <Border BorderBrush="#F1F5F9" BorderThickness="0,1,0,0" Padding="0,10">
                  <StackPanel>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/><ColumnDefinition Width="64"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Text="$t" FontWeight="SemiBold" Foreground="#1C2136" VerticalAlignment="Center"/>
                      <ComboBox x:Name="CmbInstQty_$t" Grid.Column="1" Width="56" Padding="6,3" BorderBrush="#CBD5E1" HorizontalAlignment="Left">$qty</ComboBox>
                      <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="12,0,0,0" MinWidth="190">$chks</StackPanel>
                      <TextBox x:Name="TxtInstSrc_$t" Grid.Column="3" Style="{StaticResource Input}" Margin="0" FontFamily="Consolas" FontSize="12"
                               ToolTip="Shared folder where the $t drops measurement files (File Manager Path)"/>
                      <Button x:Name="BtnInstMore_$t" Grid.Column="4" Style="{StaticResource SecondaryBtn}" Content="More paths" Tag="$t"
                              Padding="10,5" FontSize="12" Margin="8,0,0,0"/>
                    </Grid>
                    <Grid x:Name="PanelInstMore_$t" Visibility="Collapsed" Margin="0,10,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="164"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Text="Error path" Style="{StaticResource Label}"/>
                      <TextBox   Grid.Row="0" Grid.Column="1" x:Name="TxtInstErr_$t" Style="{StaticResource Input}" FontFamily="Consolas" FontSize="12"
                                 ToolTip="Rejected files (File Manager ErrorPath). Blank = local DoneError folder"/>
                      <TextBlock Grid.Row="1" Text="Broadcast (MES)" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                      <TextBox   Grid.Row="1" Grid.Column="1" x:Name="TxtInstBc_$t" Style="{StaticResource Input}" Margin="0" FontFamily="Consolas" FontSize="12"
                                 ToolTip="Data Collector BroadcastFilePaths. Blank = NA"/>
                    </Grid>
                  </StackPanel>
                </Border>
"@
}

# Run page step rows (one per step definition)
$stepFrag = foreach ($s in $StepDefs) {
    $n    = $s.Index
    $name = [System.Security.SecurityElement]::Escape($s.Name)
    $line = if ($n -lt 13) { '0,0,0,1' } else { '0' }
    @"
                <Border x:Name="RowStep$n" BorderBrush="#F1F5F9" BorderThickness="$line" Padding="0,5">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="22"/><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="TxtStep${n}Icon" Text="o" FontSize="14" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Step $n" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="2" Text="$name" FontWeight="SemiBold" Foreground="#1C2136" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtStep${n}Status" Grid.Column="3" Text="Pending" FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center"/>
                    <Button x:Name="BtnRerun$n" Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Tag="$n"
                            Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
                  </Grid>
                </Border>
"@
}
[xml]$xaml = $xamlText.Replace('<!--DATAAPPS_INSTRUMENTS-->', ($instFrag -join "`n")).Replace('<!--STEP_ROWS-->', ($stepFrag -join "`n"))

# Build window
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$controls = @{}
$xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $controls[$_.Name] = $window.FindName($_.Name)
}

# Logo (left), app icon (right, and the window / taskbar icon)
function Get-ImageFile([string]$Name) {
    $path = Join-Path $Script:RootDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource   = [Uri]::new($path, [System.UriKind]::Absolute)
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    return $bmp
}
$bmp = Get-ImageFile 'APC Logo.png'
if ($bmp) { $controls['ImgLogo'].Source = $bmp }
$bmp = Get-ImageFile 'APC Configuration Manager Icon.png'
if ($bmp) { $controls['ImgAppIcon'].Source = $bmp; $window.Icon = $bmp }

# Init controls
$controls['TxtUsername'].Text = "$env:USERDOMAIN\"
foreach ($site in $manifest.Sites) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $site
    $controls['CmbSiteCode'].Items.Add($item) | Out-Null
}

# Auto-populate Site DB fields from manifest SiteServers when site selection changes
function Update-SiteDBFields {
    $site = if ($controls['CmbSiteCode'].SelectedItem) { $controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    if (-not $site -or -not $manifest.SiteServers) { return }
    $srv = $manifest.SiteServers.PSObject.Properties[$site]
    if (-not $srv) { return }
    $entry = $srv.Value
    if ($entry.Host) {
        $controls['TxtSiteDBHost'].Text    = $entry.Host
        $controls['TxtSiteDBHost'].IsReadOnly = $true
        $controls['TxtSiteDBHost'].Background = [System.Windows.Media.Brushes]::WhiteSmoke
    } else {
        $controls['TxtSiteDBHost'].Text    = ''
        $controls['TxtSiteDBHost'].IsReadOnly = $false
        $controls['TxtSiteDBHost'].Background = [System.Windows.Media.Brushes]::White
    }
    if ($entry.User) {
        $controls['TxtSiteDBUser'].Text    = $entry.User
        $controls['TxtSiteDBUser'].IsReadOnly = $true
        $controls['TxtSiteDBUser'].Background = [System.Windows.Media.Brushes]::WhiteSmoke
    } else {
        $controls['TxtSiteDBUser'].Text    = ''
        $controls['TxtSiteDBUser'].IsReadOnly = $false
        $controls['TxtSiteDBUser'].Background = [System.Windows.Media.Brushes]::White
    }
    if ($entry.PasswordB64) {
        try {
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.PasswordB64))
            $controls['PwdSiteDB'].Password = $decoded
            $decoded = ''
        } catch { }
    } else {
        $controls['PwdSiteDB'].Password = ''
    }
}

# Prefill Data Applications instrument selection from manifest SiteDefaults
function Update-DataAppsDefaults {
    $site = if ($controls['CmbSiteCode'].SelectedItem) { $controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    $da   = $manifest.DataApps
    $defs = if ($site -and $da.SiteDefaults.PSObject.Properties[$site]) { $da.SiteDefaults.$site } else { $da.SiteDefaults.Default }
    $controls['TxtDataRoot'].Text = $da.LocalDataRoot
    foreach ($inst in $da.Instruments) {
        $t = $inst.Type
        $p = $defs.PSObject.Properties[$t]
        $d = if ($p) { $p.Value } else { $null }
        $controls["CmbInstQty_$t"].SelectedIndex = if ($d) { [math]::Max(0, [int]$d.Count - 1) } else { 0 }
        foreach ($n in 1,2,3) { $controls["ChkInst_${t}_$n"].IsChecked = [bool]($d -and ($n -in @($d.CNCs))) }
        $controls["TxtInstSrc_$t"].Text = if ($d) { $d.SourcePath }    else { '' }
        $controls["TxtInstErr_$t"].Text = if ($d) { $d.ErrorPath }     else { '' }
        $controls["TxtInstBc_$t"].Text  = if ($d) { $d.BroadcastPath } else { '' }
    }
}

function Update-DataAppsCNCVisibility {
    param([int]$CncCount)
    foreach ($inst in $manifest.DataApps.Instruments) {
        foreach ($n in 1,2,3) {
            $controls["ChkInst_$($inst.Type)_$n"].Visibility = if ($n -le $CncCount) { 'Visible' } else { 'Collapsed' }
        }
    }
}

function Get-DataAppsSelection {
    param([int]$CncCount)
    foreach ($inst in $manifest.DataApps.Instruments) {
        $t    = $inst.Type
        $cncs = @(1..$CncCount | Where-Object { $controls["ChkInst_${t}_$_"].IsChecked -eq $true })
        $qty  = if ($controls["CmbInstQty_$t"].SelectedItem) { [int]$controls["CmbInstQty_$t"].SelectedItem.Content } else { 1 }
        @{
            Type          = $t
            Count         = $qty
            CNCs          = $cncs
            SourcePath    = $controls["TxtInstSrc_$t"].Text.Trim()
            ErrorPath     = $controls["TxtInstErr_$t"].Text.Trim()
            BroadcastPath = $controls["TxtInstBc_$t"].Text.Trim()
        }
    }
}

# "More paths" shows an instrument's error and broadcast paths (the button's Tag is the instrument type)
foreach ($inst in $manifest.DataApps.Instruments) {
    $controls["BtnInstMore_$($inst.Type)"].Add_Click({
        param($btn)
        $panel = $controls["PanelInstMore_$($btn.Tag)"]
        $open  = $panel.Visibility -ne 'Visible'
        $panel.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
        $btn.Content      = if ($open) { 'Less' } else { 'More paths' }
    })
}


# ---- DOC assignment -----------------------------------------------------------

function Get-DOCCount {
    foreach ($n in 3, 2, 1) { if ($controls["RbDoc$n"].IsChecked) { return $n } }
    return 3
}

function Update-DOCMachineChoices {
    # Collect which machine name each active box has selected
    $selected = @{}
    foreach ($n in 1,2,3) {
        $cmb = $controls["CmbDOCMachine$n"]
        if ($cmb -and $cmb.SelectedItem) { $selected[$n] = $cmb.SelectedItem.Content }
    }
    # For each box: enable all items, then disable those chosen by the OTHER boxes
    foreach ($n in 1,2,3) {
        $cmb = $controls["CmbDOCMachine$n"]
        if (-not $cmb) { continue }
        $othersChosen = $selected.Keys | Where-Object { $_ -ne $n } | ForEach-Object { $selected[$_] }
        foreach ($item in $cmb.Items) {
            $item.IsEnabled = $item.Content -notin $othersChosen
        }
    }
}

# Family, Device Nr and DLL for each assigned machine, as Step 8 will derive them
function Update-DOCDetails {
    foreach ($n in 1,2,3) {
        $cmb  = $controls["CmbDOCMachine$n"]
        $name = if ($cmb.SelectedItem) { $cmb.SelectedItem.Content } else { '' }
        $m    = @($Global:FetchedMachines) | Where-Object { $_.MachineName -eq $name } | Select-Object -First 1
        $fam = ''; $dev = ''; $dll = ''; $tip = $null; $devColor = '#1C2136'
        if ($m) {
            $info = Get-CNCDeviceInfo -Machine $m -Manifest $manifest
            $fam  = $info.Family; $dll = $info.DriverDll
            if ($info.Error) { $dev = 'Error'; $tip = $info.Error; $devColor = '#EF4444' } else { $dev = $info.DeviceNr }
        }
        $controls["TxtDOCFam$n"].Text       = $fam
        $controls["TxtDOCDev$n"].Text       = $dev
        $controls["TxtDOCDev$n"].ToolTip    = $tip
        $controls["TxtDOCDev$n"].Foreground = $devColor
        $controls["TxtDOCDll$n"].Text       = $dll
    }
}

function Update-DOCRows {
    $cnt = Get-DOCCount
    $controls['GridDOCRow2'].Visibility = if ($cnt -ge 2) { 'Visible' } else { 'Collapsed' }
    $controls['GridDOCRow3'].Visibility = if ($cnt -ge 3) { 'Visible' } else { 'Collapsed' }
    Update-DOCMachineChoices
    Update-DOCDetails
    Update-DataAppsCNCVisibility -CncCount $cnt
}

foreach ($n in 1,2,3) {
    $controls["RbDoc$n"].Add_Checked({ Update-DOCRows })
    $controls["CmbDOCMachine$n"].Add_SelectionChanged({ Update-DOCMachineChoices; Update-DOCDetails })
}

# ---- Run mode and license -----------------------------------------------------

$controls['TxtModeDescReviewed'].Text = "Real run of the reviewed steps ($(@(1..13 | Where-Object { $_ -notin (Get-RunModeSkipSteps -Manifest $manifest -Mode Reviewed) }) -join ', ')); the others are skipped."
$controls['TxtModeDescTest'].Text     = "Works on sandbox copies in the run folder (C:\APC_Config\<type>_<time>\Sandbox); nothing installed is changed. Runs steps $(@(1..13 | Where-Object { $_ -notin (Get-RunModeSkipSteps -Manifest $manifest -Mode Test) }) -join ', ')."
$controls["RbMode$($manifest.RunModes.Default)"].IsChecked = $true

# CNCnetPDM license: default from manifest, editable when the checkbox is cleared
$controls['TxtLicense'].Text = $manifest.CNCnetPDM.DefaultLicense
$controls['ChkDefaultLicense'].Add_Checked({
    $controls['TxtLicense'].Text      = $manifest.CNCnetPDM.DefaultLicense
    $controls['TxtLicense'].IsEnabled = $false
})
$controls['ChkDefaultLicense'].Add_Unchecked({
    $controls['TxtLicense'].IsEnabled = $true
    $controls['TxtLicense'].Focus() | Out-Null
})

# ---- CHMI (800xA) page ------------------------------------------------------------

foreach ($h in 0..23) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = '{0:00}:00' -f $h
    $item.Tag     = $h
    [void]$controls['CmbShift1Hour'].Items.Add($item)
}
$Script:CHMIAuto    = @{}   # last auto-filled value per CSV folder box, so a typed value is kept
$Script:CHMICurrent = @{}   # VerificationOnShift read from 800xA per CNC: 'True' / 'False' / '' (could not read)
$Script:CHMIReadFor = ''    # DOC assignment the current values were read for

function Get-CHMIMachineName([int]$N) {
    $cmb = $controls["CmbDOCMachine$N"]
    if ($cmb.SelectedItem) { [string]$cmb.SelectedItem.Content } else { '' }
}

# Step 11 setting values for the chosen site and data root (manifest ABB800xA.Settings)
function Get-CHMISiteSettings {
    $site = if ($controls['CmbSiteCode'].SelectedItem) { [string]$controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    Get-800xASettings -Manifest $manifest -State @{ SiteCode = $site; DataAppsLocalRoot = $controls['TxtDataRoot'].Text.Trim() }
}

# Reads Cell_n:VerificationOnShift for each DOC-assigned CNC through the 800xA kit (read-only, about 1 s per cell)
# and pre-selects Button / Both. Read again only when the DOC assignment changes.
function Read-CHMICurrentValues {
    $cnt = Get-DOCCount
    $key = (1..$cnt | ForEach-Object { Get-CHMIMachineName $_ }) -join '|'
    if ($key -eq $Script:CHMIReadFor) { return }
    $Script:CHMIReadFor = $key
    $Script:CHMICurrent = @{}
    $prop = @($manifest.ABB800xA.Properties | Where-Object { [string]$_.Value -eq '{VERIFYONSHIFT}' }) | Select-Object -First 1
    $kit  = Get-800xAKit -Manifest $manifest
    if ($prop -and $kit.Problems.Count -eq 0) {
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            foreach ($n in 1..$cnt) {
                $id = ([string]$prop.ItemId).Replace('{CELL}', [string]$n)
                $r  = Invoke-800xAGPCall -Kit $kit -ItemId $id -Server ([string]$manifest.ABB800xA.OpcServer)
                $Script:CHMICurrent[$n] = if ($r.Success -and $r.Before -in 'True', 'False') { [string]$r.Before } else { '' }
            }
        } catch {
            $Script:CHMICurrent = @{}
        } finally { $window.Cursor = $null }
    }
    foreach ($n in 1..3) {
        $controls["CmbCHMITrigger$n"].SelectedIndex = switch ([string]$Script:CHMICurrent[$n]) { 'True' { 1 } 'False' { 0 } default { -1 } }
    }
}

function Get-CHMITriggerText($Value) { switch ([string]$Value) { 'True' { 'Both' } 'False' { 'Button' } default { 'Unknown' } } }

function Update-CHMIShift {
    $cnt  = Get-DOCCount
    $both = @(1..$cnt | Where-Object { $sel = $controls["CmbCHMITrigger$_"].SelectedItem; $sel -and [string]$sel.Tag -eq 'True' }).Count -gt 0
    $controls['CmbShift1Hour'].IsEnabled = $both
    $controls['TxtShiftHint'].Text = if ($both) { 'Whole hours only. Written for the cells set to Both.' } else { 'Used only for cells set to Both.' }
}

function Update-CHMIPage {
    Read-CHMICurrentValues
    $cnt = Get-DOCCount
    foreach ($n in 1..3) {
        $controls["GridCHMIRow$n"].Visibility = if ($n -le $cnt) { 'Visible' } else { 'Collapsed' }
        $controls["TxtCHMIMachine$n"].Text    = Get-CHMIMachineName $n
        $controls["TxtCHMICurrent$n"].Text    = Get-CHMITriggerText $Script:CHMICurrent[$n]
        $controls["TxtCHMICurrent$n"].ToolTip = if ($Script:CHMICurrent[$n]) { $null } else { 'Could not read the value from 800xA - pick one.' }
    }
    $set = Get-CHMISiteSettings
    foreach ($pair in @(@('TxtCHMIBench', 'SAMPLECSVPATH'), @('TxtCHMIPct', 'PCT100CSVPATH'))) {
        $box = $controls[$pair[0]]
        if (-not $box.Text.Trim() -or $box.Text -eq $Script:CHMIAuto[$pair[0]]) {
            $box.Text = [string]$set[$pair[1]]
            $Script:CHMIAuto[$pair[0]] = $box.Text
        }
    }
    if (-not $controls['CmbShift1Hour'].SelectedItem -and $set['SHIFT1HOUR'] -match '^\d+$' -and [int]$set['SHIFT1HOUR'] -le 23) {
        $controls['CmbShift1Hour'].SelectedIndex = [int]$set['SHIFT1HOUR']
    }
    Update-CHMIShift
}

foreach ($n in 1..3) { $controls["CmbCHMITrigger$n"].Add_SelectionChanged({ Update-CHMIShift }) }

function Test-CHMIPage {
    $cnt = Get-DOCCount
    $missing = @(1..$cnt | Where-Object { -not $controls["CmbCHMITrigger$_"].SelectedItem } | ForEach-Object { "CNC$_" })
    if ($missing) { Show-Warning "Pick Button or Both for: $($missing -join ', ')"; return $false }
    if ($controls['CmbShift1Hour'].IsEnabled -and -not $controls['CmbShift1Hour'].SelectedItem) { Show-Warning "Pick the first shift start hour."; return $false }
    foreach ($b in 'TxtCHMIBench', 'TxtCHMIPct') {
        $t = $controls[$b].Text.Trim()
        if (-not $t) { Show-Warning "Enter both inspection CSV folders."; return $false }
        if ($t -match '"') { Show-Warning "The inspection CSV folders cannot contain double quotes."; return $false }
    }
    return $true
}

# State['800xASettings'] for Step 11: CSV folders, first shift hour and the per-cell trigger (CELLn.VERIFYONSHIFT)
function Get-CHMISettingsState {
    $set = @{ SAMPLECSVPATH = $controls['TxtCHMIBench'].Text.Trim(); PCT100CSVPATH = $controls['TxtCHMIPct'].Text.Trim() }
    if ($controls['CmbShift1Hour'].SelectedItem) { $set['SHIFT1HOUR'] = [int]$controls['CmbShift1Hour'].SelectedItem.Tag }
    foreach ($n in 1..(Get-DOCCount)) {
        $sel = $controls["CmbCHMITrigger$n"].SelectedItem
        if ($sel) { $set["CELL$n"] = @{ VERIFYONSHIFT = [string]$sel.Tag } }
    }
    return $set
}

# ---- Helpers ----------------------------------------------------------------

function Test-InstallerCredential {
    param([string]$DomainUser, [string]$Password)
    $parts = $DomainUser -split '\\'
    if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { return $false }
    try {
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain, $parts[0])
        return $ctx.ValidateCredentials($parts[1], $Password)
    } catch { return $false }
}

function Show-Warning {
    param([string]$Message, [string]$Title = 'Missing')
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Warning') | Out-Null
}

function Set-StepState {
    param([int]$Index, [string]$State)
    $icon   = $controls["TxtStep${Index}Icon"]
    $status = $controls["TxtStep${Index}Status"]
    $rerun  = $controls["BtnRerun${Index}"]
    switch ($State) {
        'Pending' { $icon.Text = [string][char]0x25CB; $icon.Foreground = '#94A3B8'; $status.Text = 'Pending';    $status.Foreground = '#94A3B8'; $rerun.Visibility = 'Collapsed' }
        'Running' { $icon.Text = [string][char]0x25B6; $icon.Foreground = '#4361EE'; $status.Text = 'Running...'; $status.Foreground = '#4361EE'; $rerun.Visibility = 'Collapsed' }
        'Done'    { $icon.Text = [string][char]0x2713; $icon.Foreground = '#166534'; $status.Text = 'Complete';   $status.Foreground = '#166534'; $rerun.Visibility = 'Collapsed' }
        'Paused'  { $icon.Text = [string][char]0x23F8; $icon.Foreground = '#D97706'; $status.Text = 'Manual step';$status.Foreground = '#D97706'; $rerun.Visibility = 'Collapsed' }
        'Failed'  { $icon.Text = [string][char]0x2717; $icon.Foreground = '#EF4444'; $status.Text = 'Failed';     $status.Foreground = '#EF4444'; $rerun.Visibility = 'Visible'   }
        'Skipped' { $icon.Text = '-';                  $icon.Foreground = '#CBD5E1'; $status.Text = 'Skipped';    $status.Foreground = '#94A3B8'; $rerun.Visibility = 'Collapsed' }
    }
}

function Get-CurrentState {
    $site = if ($controls['CmbSiteCode'].SelectedItem) { $controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    return @{
        CurrentPhase     = 1
        OperatorName     = $controls['TxtUsername'].Text.Trim()
        OperatorRole     = 'Service Account'
        SiteCode         = $site
        SiteDBHost       = $controls['TxtSiteDBHost'].Text.Trim()
        SiteDBUser       = $controls['TxtSiteDBUser'].Text.Trim()
        SINCEmail        = $controls['TxtSINCEmail'].Text.Trim()
        DOCCount         = Get-DOCCount
        VMHostname       = $env:COMPUTERNAME
        StartTime        = (Get-Date -Format 'o')
        CompletedPhases  = @()
        CNCMachines      = @()
        DeviceWisePort   = 0
        DeviceWiseToken  = ''
    }
}

function Save-State {
    param([hashtable]$State)
    $dir = Split-Path $Script:StateFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    $safe = @{}
    foreach ($k in $State.Keys) {
        if ($State[$k] -isnot [System.Security.SecureString]) { $safe[$k] = $State[$k] }
    }
    $json = $safe | ConvertTo-Json -Depth 10
    $json | Set-Content $Script:StateFile -Encoding UTF8
    if ($State['RunRoot']) { $json | Set-Content (Join-Path $State['RunRoot'] 'config_state.json') -Encoding UTF8 }
}

# The window's run log (what "Show log" shows) -> <RunRoot>\Logs\Wizard.log, rewritten after each step
function Save-RunLog {
    if (-not $Script:AutoState -or -not $Script:AutoState['RunRoot']) { return }
    try {
        $dir = Join-Path $Script:AutoState['RunRoot'] 'Logs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'Wizard.log'), $controls['LogAll'].Text)
    } catch { }
}

function Add-LogSection {
    param([string]$Title)
    $bar = '=' * 58; $pad = ' ' * ([math]::Max(0, (58 - $Title.Length - 4)) / 2)
    $controls['LogAll'].AppendText("`r`n$bar`r`n$pad  $Title`r`n$bar`r`n")
    $controls['LogAll'].ScrollToEnd()
}

# ---- Wizard pages -------------------------------------------------------------

$Script:PageIndex = 0
$Script:RunState  = 'none'    # none | running | done

function Get-ConfigType {
    foreach ($id in $Script:ConfigTypes.Keys) { if ($controls["RbType_$id"].IsChecked) { return $id } }
    return 'initial'
}

function Get-PickedComponents {
    @($Script:Components.Keys | Where-Object { $controls["ChkComp_$_"].IsChecked -eq $true })
}

# Steps the chosen type configures (before the run mode removes any)
function Get-PlanSteps {
    switch (Get-ConfigType) {
        'initial' { return @(1..13) }
        'verify'  { return @(1, 13) }
        default {
            $steps = @(1, 12, 13)
            foreach ($c in Get-PickedComponents) { $steps += $Script:Components[$c].Steps }
            return @($steps | Sort-Object -Unique)
        }
    }
}

function Get-WizardPages {
    $type = Get-ConfigType
    switch ($type) {
        'initial' { return @('type', 'signin', 'machines', 'components', 'dataapps', 'chmi', 'review', 'run', 'verify') }
        'verify'  { return @('type', 'signin', 'machines', 'review', 'run', 'verify') }
        default {
            $picked = Get-PickedComponents
            $pages  = @('type', 'signin', 'scope', 'machines')
            if ('dw' -in $picked -or 'cnc' -in $picked) { $pages += 'components' }
            if ('da' -in $picked) { $pages += 'dataapps' }
            if ('chmi' -in $picked) { $pages += 'chmi' }
            return $pages + @('review', 'run', 'verify')
        }
    }
}

# Run mode: Verify (read-only, no mode choice), else Reviewed / Full / Test from the Review page
function Get-RunMode {
    if ((Get-ConfigType) -eq 'verify') { return 'Verify' }
    foreach ($m in 'Reviewed', 'Full', 'Test') { if ($controls["RbMode$m"].IsChecked) { return $m } }
    return 'Full'
}

function Get-RunSkipSteps {
    $plan = Get-PlanSteps
    $mode = Get-RunMode
    $skip = @(1..13 | Where-Object { $_ -notin $plan })
    if ($mode -ne 'Verify') { $skip += @(Get-RunModeSkipSteps -Manifest $manifest -Mode $mode) }
    return @($skip | Sort-Object -Unique)
}

function New-TextBlock {
    param([string]$Text, [string]$Color = '#1C2136', [string]$Weight = 'Normal', [double]$Size = 13)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.Foreground = $Color; $tb.FontWeight = $Weight; $tb.FontSize = $Size
    $tb.TextWrapping = 'Wrap'; $tb.VerticalAlignment = 'Center'
    return $tb
}

function Update-NavList {
    param([string[]]$Pages)
    $nav = $controls['NavList']
    $nav.Children.Clear()
    for ($i = 0; $i -lt $Pages.Count; $i++) {
        $current = $i -eq $Script:PageIndex
        $done    = $i -lt $Script:PageIndex
        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 24; $dot.Height = 24; $dot.CornerRadius = 12; $dot.Margin = '0,0,10,0'
        $dot.Background = if ($current) { '#4361EE' } elseif ($done) { '#DCFCE7' } else { '#F1F5F9' }
        $dotText = New-TextBlock -Text $(if ($done) { [string][char]0x2713 } else { [string]($i + 1) }) -Size 12 -Weight 'Bold' `
                       -Color $(if ($current) { '#FFFFFF' } elseif ($done) { '#166534' } else { '#64748B' })
        $dotText.HorizontalAlignment = 'Center'
        $dot.Child = $dotText
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        [void]$row.Children.Add($dot)
        [void]$row.Children.Add((New-TextBlock -Text $Script:PageLabels[$Pages[$i]] -Weight $(if ($current) { 'SemiBold' } else { 'Normal' }) `
                                   -Color $(if ($current) { '#1C2136' } elseif ($done) { '#334155' } else { '#94A3B8' })))
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style      = $window.FindResource('NavItemBtn')
        $btn.Content    = $row
        $btn.Tag        = $i
        $btn.Background = if ($current) { '#EEF2FF' } else { 'Transparent' }
        $canGo = $done -and $Script:RunState -ne 'running'
        $btn.Cursor     = if ($canGo) { 'Hand' } else { 'Arrow' }
        if ($canGo) { $btn.Add_Click({ param($b) $Script:PageIndex = [int]$b.Tag; Update-Wizard }) }
        [void]$nav.Children.Add($btn)
    }
}

function Update-ReviewPage {
    $type = Get-ConfigType
    $site = if ($controls['CmbSiteCode'].SelectedItem) { $controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    $rows = [ordered]@{ 'Configuration type' = $Script:ConfigTypes[$type].Name; 'Site' = $site }
    if ($type -in 'component', 'update') {
        $picked = Get-PickedComponents | ForEach-Object { ($Script:Components[$_].Label -split ' \(')[0] }
        $rows['Components'] = if ($picked) { $picked -join ', ' } else { 'None selected' }
    }
    $cnt = Get-DOCCount
    $rows['DOC instances'] = (1..$cnt | ForEach-Object {
        $cmb = $controls["CmbDOCMachine$_"]
        "CNC$_ $(if ($cmb.SelectedItem) { $cmb.SelectedItem.Content } else { '-' })"
    }) -join "  $Script:Dot  "
    if ('chmi' -in (Get-WizardPages)) {
        $rows['Verification trigger'] = (1..$cnt | ForEach-Object {
            $sel = $controls["CmbCHMITrigger$_"].SelectedItem
            $val = if ($sel) { [string]$sel.Tag } else { '' }
            "CNC$_ $(Get-CHMITriggerText $val)$(if ($val -and $Script:CHMICurrent[$_] -and $val -ne $Script:CHMICurrent[$_]) { ' (changed)' })"
        }) -join "  $Script:Dot  "
    }
    if ($type -eq 'verify') { $rows['Changes to this VM'] = 'None (read-only)' }

    $panel = $controls['PanelSummary']
    $panel.Children.Clear()
    foreach ($k in $rows.Keys) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = '0,0,0,6'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '180'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
        $v = New-TextBlock -Text $rows[$k] -Weight 'SemiBold'
        [System.Windows.Controls.Grid]::SetColumn($v, 1)
        [void]$g.Children.Add((New-TextBlock -Text $k -Color '#475569'))
        [void]$g.Children.Add($v)
        [void]$panel.Children.Add($g)
    }

    $isVerify = $type -eq 'verify'
    $controls['PanelRunMode'].Visibility  = if ($isVerify) { 'Collapsed' } else { 'Visible' }
    $controls['PanelReadOnly'].Visibility = if ($isVerify) { 'Visible' } else { 'Collapsed' }
    $controls['TxtReviewHint'].Text = if ($isVerify) { 'Check the summary, then start the verification.' } else { 'Check the summary, choose how to run, then start.' }

    $plan = Get-PlanSteps
    $skip = Get-RunSkipSteps
    $wrap = $controls['WrapRunSteps']
    $wrap.Children.Clear()
    foreach ($s in $Script:StepDefs | Where-Object { $_.Index -in $plan }) {
        $skipped = $s.Index -in $skip
        $chip = New-Object System.Windows.Controls.Border
        $chip.CornerRadius = 10; $chip.Padding = '8,3'; $chip.Margin = '0,0,6,6'
        $chip.Background = if ($skipped) { '#F1F5F9' } else { '#EEF2FF' }
        $label = New-TextBlock -Text "Step $($s.Index) $($s.Name)" -Size 12 -Color $(if ($skipped) { '#94A3B8' } else { '#3451D1' })
        if ($skipped) { $label.TextDecorations = [System.Windows.TextDecorations]::Strikethrough }
        $chip.Child = $label
        [void]$wrap.Children.Add($chip)
    }
}

function Update-VerifyPage {
    $controls['PanelReason'].Visibility = if ((Get-ConfigType) -eq 'verify') { 'Visible' } else { 'Collapsed' }
}

# Verification counts from the last Step 13 summary line in a log
function Update-VerifySummary {
    param([string]$LogText)
    $m = [regex]::Matches($LogText, 'Summary: (\d+) PASS / (\d+) WARN / (\d+) FAIL / (\d+) manual')
    $controls['TxtVerifySummary'].Text = if ($m.Count -gt 0) {
        $g = $m[$m.Count - 1].Groups
        "$($g[1].Value) passed  $Script:Dot  $($g[2].Value) warnings  $Script:Dot  $($g[3].Value) failed  $Script:Dot  $($g[4].Value) manual items left blank in the draft"
    } else {
        'Verification has not run yet. Generate the draft checklist to run it.'
    }
}

function Update-Wizard {
    $pages = Get-WizardPages
    if ($Script:PageIndex -ge $pages.Count) { $Script:PageIndex = $pages.Count - 1 }
    $key = $pages[$Script:PageIndex]
    foreach ($p in $Script:PagePanels.Keys) {
        $controls[$Script:PagePanels[$p]].Visibility = if ($p -eq $key) { 'Visible' } else { 'Collapsed' }
    }
    Update-NavList -Pages $pages

    $controls['TxtTypeChip'].Text   = $Script:ConfigTypes[(Get-ConfigType)].Name
    $controls['TxtFooterStep'].Text = "Step $($Script:PageIndex + 1) of $($pages.Count) $Script:Dot $($Script:PageLabels[$key])"
    $controls['TxtScopeHint'].Text  = if ((Get-ConfigType) -eq 'update') {
        'Only the selected components are updated with the values entered in this wizard; everything else is left as it is.'
    } else { 'Only the selected components are configured; everything else is left as it is.' }

    $running = $Script:RunState -eq 'running'
    $controls['BtnBack'].IsEnabled = $Script:PageIndex -gt 0 -and -not $running
    $controls['BtnNext'].IsEnabled = -not $running -and -not ($key -eq 'run' -and $Script:RunState -ne 'done')
    $controls['BtnNext'].Content   = switch ($key) {
        'review' { if ((Get-ConfigType) -eq 'verify') { 'Start verification' } else { 'Start configuration' } }
        'run'    { 'Continue' }
        'verify' { 'Finish' }
        default  { 'Next' }
    }
    if ($key -eq 'chmi')   { Update-CHMIPage }
    if ($key -eq 'review') { Update-ReviewPage }
    if ($key -eq 'verify') { Update-VerifyPage }
    $controls['MainScroller'].ScrollToTop()
}

foreach ($id in $Script:ConfigTypes.Keys) { $controls["RbType_$id"].Add_Checked({ Update-Wizard }) }
foreach ($c in $Script:Components.Keys) {
    $controls["ChkComp_$c"].Add_Checked({ Update-Wizard })
    $controls["ChkComp_$c"].Add_Unchecked({ Update-Wizard })
}
foreach ($m in 'Reviewed', 'Full', 'Test') { $controls["RbMode$m"].Add_Checked({ if ($controls['PageReview'].Visibility -eq 'Visible') { Update-ReviewPage } }) }

# ---- Module runner ----------------------------------------------------------

$Script:RSSync = $null

function Start-ModuleInWindow {
    param(
        [string]$ModuleFile,
        [string]$FunctionName,
        [hashtable]$State,
        [System.Windows.Controls.TextBox]$LogBox,
        [scriptblock]$OnDone = $null
    )

    $Script:RSSync = [hashtable]::Synchronized(@{
        Queue    = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        Done     = $false
        Success  = $false
        HasFails = $false
        Paused   = $false
    })

    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('_sync',     $Script:RSSync)
    $rs.SessionStateProxy.SetVariable('_manifest', $Script:RunManifest)
    $rs.SessionStateProxy.SetVariable('_state',    $State)
    $rs.SessionStateProxy.SetVariable('_modPath',  (Join-Path $Script:ModulesDir $ModuleFile))
    $rs.SessionStateProxy.SetVariable('_fn',       $FunctionName)

    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        function Write-Log {
            param([string]$Level, [string]$Message)
            $ts = Get-Date -Format 'HH:mm:ss'
            $_sync.Queue.Enqueue("[$ts][$Level] $Message")
        }
        function Add-Result {
            param([string]$Phase, [string]$Check, [string]$Status, [string]$Detail = '')
            if ($Status -eq 'FAIL') { $_sync.HasFails = $true }
            $suffix = if ($Detail) { "  - $Detail" } else { '' }
            $_sync.Queue.Enqueue("[$Status] $Phase | $Check$suffix")
        }
        $Global:ConfigResults = [System.Collections.Generic.List[hashtable]]::new()
        try {
            . $_modPath
            & $_fn -Manifest $_manifest -State $_state -NonInteractive
            $_sync.Done = $true; $_sync.Success = $true
        } catch {
            $_sync.Queue.Enqueue("[ERROR] $_")
            $_sync.Done = $true; $_sync.Success = $false
        }
    })
    $handle = $ps.BeginInvoke()

    $capturedLog    = $LogBox;    $capturedPS    = $ps
    $capturedRS     = $rs;        $capturedHandle = $handle
    $capturedOnDone = $OnDone;    $capturedSync  = $Script:RSSync

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $line = [string]::Empty
        while ($capturedSync.Queue.TryDequeue([ref]$line)) {
            $capturedLog.AppendText("$line`r`n"); $capturedLog.ScrollToEnd()
        }
        if ($capturedSync.Done) {
            $args[0].Stop()
            try { $capturedPS.EndInvoke($capturedHandle) } catch {}
            $capturedRS.Close()
            $overallOk = $capturedSync.Success -and (-not $capturedSync.HasFails)
            if ($capturedOnDone) { & $capturedOnDone $overallOk }
        }
    }.GetNewClosure())
    $timer.Start()
}

# ---- Auto-run chain ---------------------------------------------------------

$Script:AutoIndex      = 0
$Script:AutoState      = $null
$Script:StepStartTime  = $null
$Script:StartStep      = 1
$Script:RunTotal       = 0
$Script:RunDone        = 0
$Script:RerunIndex     = 0
$Global:FetchedMachines = @()

function Update-RunProgress {
    $controls['BarOverall'].Maximum    = [math]::Max(1, $Script:RunTotal)
    $controls['BarOverall'].Value      = $Script:RunDone
    $controls['TxtProgressLabel'].Text = "$($Script:RunDone) / $($Script:RunTotal) steps"
}

function Complete-Run {
    param([string]$Title)
    $Script:RunState = 'done'
    $controls['TxtRunTitle'].Text = $Title
    Save-RunLog
    Update-VerifySummary -LogText $controls['LogAll'].Text
    Update-Wizard
}

function Run-NextAutoModule {
    if ($Script:AutoIndex -ge $Script:StepDefs.Count) {
        Complete-Run -Title 'Finished'
        return
    }

    $mod  = $Script:StepDefs[$Script:AutoIndex]
    $plan = Get-PlanSteps
    if ($mod.Index -in $Script:SkipSteps -or $mod.Index -lt $Script:StartStep) {
        if ($mod.Index -in $plan) {
            Set-StepState -Index $mod.Index -State 'Skipped'
            $controls['LogAll'].AppendText("-- Step $($mod.Index) $($mod.Name): skipped ($Script:RunModeName) --`r`n")
        }
        $Script:AutoIndex++
        Run-NextAutoModule
        return
    }
    Add-LogSection -Title "Step $($mod.Index) -- $($mod.Name)"
    Set-StepState -Index $mod.Index -State 'Running'
    $Script:StepStartTime = Get-Date

    Start-ModuleInWindow `
        -ModuleFile   $mod.File `
        -FunctionName $mod.Fn `
        -State        $Script:AutoState `
        -LogBox       $controls['LogAll'] `
        -OnDone       {
            param([bool]$ok)
            $doneIndex = $Script:StepDefs[$Script:AutoIndex].Index
            $elapsed   = (Get-Date) - $Script:StepStartTime
            $timeStr   = if ($elapsed.TotalSeconds -lt 60) { "$([math]::Round($elapsed.TotalSeconds)) sec" } else { "$($elapsed.Minutes) min $($elapsed.Seconds) sec" }
            $controls['LogAll'].AppendText("-- $(if ($ok) {'Completed'} else {'Failed'}) in $timeStr --`r`n")
            $controls['LogAll'].ScrollToEnd()
            Save-RunLog

            # Step 11 (CHMI) uses Paused state when manual steps are required
            if ($doneIndex -eq 11 -and $Script:RSSync.Paused) {
                Set-StepState -Index $doneIndex -State 'Paused'
            } else {
                Set-StepState -Index $doneIndex -State $(if ($ok) { 'Done' } else { 'Failed' })
            }
            $Script:RunDone++
            Update-RunProgress

            if (-not $ok) {
                $modName = $Script:StepDefs[$Script:AutoIndex].Name
                $choice  = [System.Windows.MessageBox]::Show(
                    "$modName reported errors - see the log.`n`nContinue to the next step?",
                    "Step Failed", "YesNo", "Warning")
                if ($choice -ne 'Yes') { Complete-Run -Title 'Stopped'; return }
            }
            $Script:AutoIndex++
            Run-NextAutoModule
        }
}

# ---- Site DB fetch (Sign in page -> Next) --------------------------------------

# Called on the UI thread when the fetch finishes; fills the DOC drop-downs and moves to the next page
function Complete-MachineFetch {
    param([object[]]$MachineList, [string]$ErrorText)
    $controls['BtnNext'].IsEnabled = $true
    $site = $controls['CmbSiteCode'].SelectedItem.Content
    if ($ErrorText) {
        $controls['TxtProceedStatus'].Text       = "Error: $ErrorText"
        $controls['TxtProceedStatus'].Foreground = '#EF4444'
        [System.Windows.MessageBox]::Show("Site DB query failed:`n$ErrorText", "Fetch Error", "OK", "Error") | Out-Null
        return
    }
    if (-not $MachineList -or $MachineList.Count -eq 0) {
        $controls['TxtProceedStatus'].Text       = "No machines found for site $site"
        $controls['TxtProceedStatus'].Foreground = '#D97706'
        return
    }
    $Global:FetchedMachines = $MachineList
    $controls['TxtProceedStatus'].Text       = "$($MachineList.Count) machine(s) loaded from the $site Site DB"
    $controls['TxtProceedStatus'].Foreground = '#166534'
    $controls['TxtMachineCount'].Text        = "$($MachineList.Count) machine(s) loaded from the $site Site DB. DOC n = CNC n; only assigned machines are configured."

    # Populate DOC machine drop-downs; keep a previous choice when the machine is still there, else default each to a different machine
    foreach ($n in 1,2,3) {
        $cmb  = $controls["CmbDOCMachine$n"]
        $prev = if ($cmb.SelectedItem) { $cmb.SelectedItem.Content } else { '' }
        $cmb.Items.Clear()
        foreach ($m in $MachineList) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $m.MachineName
            $cmb.Items.Add($item) | Out-Null
        }
        $idx = [array]::IndexOf(@($MachineList | ForEach-Object { $_.MachineName }), $prev)
        if ($idx -lt 0) { $idx = [math]::Min($n - 1, $cmb.Items.Count - 1) }
        if ($cmb.Items.Count -gt 0) { $cmb.SelectedIndex = $idx }
    }
    Update-DOCRows
    $Script:PageIndex++
    Update-Wizard
}

function Start-MachineFetch {
    $siteCode  = $controls['CmbSiteCode'].SelectedItem.Content
    $dbHost    = $controls['TxtSiteDBHost'].Text.Trim()
    $dbUser    = $controls['TxtSiteDBUser'].Text.Trim()
    $dbPwd     = $controls['PwdSiteDB'].Password

    $controls['BtnNext'].IsEnabled           = $false
    $controls['TxtProceedStatus'].Text       = 'Connecting to Site DB...'
    $controls['TxtProceedStatus'].Foreground = '#4361EE'

    $fetchSync = [hashtable]::Synchronized(@{
        Done     = $false
        Machines = @()
        Error    = ''
    })

    $rs = [RunspaceFactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('_sync',     $fetchSync)
    $rs.SessionStateProxy.SetVariable('_host',     $dbHost)
    $rs.SessionStateProxy.SetVariable('_user',     $dbUser)
    $rs.SessionStateProxy.SetVariable('_pwd',      $dbPwd)
    $rs.SessionStateProxy.SetVariable('_site',     $siteCode)
    $rs.SessionStateProxy.SetVariable('_manifest', $manifest)

    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $db   = $_manifest.SiteDB
            $cols = $db.Columns

            # Resolve psql path from manifest
            $pgBin = $_manifest.PostgreSQL.BinDir
            $psql  = Join-Path $pgBin 'psql.exe'
            if (-not (Test-Path $psql)) { $psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe' }
            if (-not (Test-Path $psql)) { throw "psql.exe not found" }

            # Resolve server from SiteServers[site]
            $srv  = $null
            if ($_manifest.SiteServers -and $_manifest.SiteServers.PSObject.Properties[$_site]) {
                $srv = $_manifest.SiteServers.($_site)
            }
            $resolvedHost = if ($srv -and $srv.Host)     { $srv.Host }     else { $_host }
            $resolvedUser = if ($srv -and $srv.User)     { $srv.User }     else { $_user }
            $resolvedPort = if ($srv -and $srv.Port)     { $srv.Port }     else { $db.Port }
            $resolvedDb   = if ($srv -and $srv.Database) { $srv.Database } else { $db.Database }

            # Use provided password; if empty, try manifest PasswordB64
            $resolvedPwd = $_pwd
            if (-not $resolvedPwd -and $srv -and $srv.PasswordB64) {
                $resolvedPwd = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($srv.PasswordB64))
            }

            $sql = "SELECT $($cols.MachineName),$($cols.IPAddress),$($cols.Port),$($cols.CNCType),$($cols.DLLName) FROM $($db.AssetTable) WHERE $($cols.CNCnetPDMRequired) = true ORDER BY $($cols.MachineName)"

            $env:PGPASSWORD = $resolvedPwd
            $raw = & $psql -h $resolvedHost -p $resolvedPort -U $resolvedUser -d $resolvedDb -t -A -F '|' -c $sql 2>&1
            $env:PGPASSWORD = ''
            $resolvedPwd = ''

            $errLines = $raw | Where-Object { $_ -match '^(psql:|ERROR:|FATAL:|could not connect)' }
            if ($errLines) { throw ($errLines -join '; ') }

            $machines = @()
            foreach ($line in ($raw | Where-Object { $_ -and $_ -notmatch '^\s*$' -and $_ -notmatch '^\(\d+ rows?\)' })) {
                $parts = $line -split '\|'
                if ($parts.Count -ge 4) {
                    $cncType = $parts[3].Trim()
                    $machines += [PSCustomObject]@{
                        MachineName = $parts[0].Trim()
                        IPAddress   = $parts[1].Trim()
                        Port        = $parts[2].Trim()
                        AssetFamily = $cncType
                        CNCType     = $cncType
                        DLLName     = if ($parts.Count -ge 5) { $parts[4].Trim() } else { '' }
                    }
                }
            }
            $_sync.Machines = $machines
            $_sync.Done     = $true
        } catch {
            $_sync.Error = $_.Exception.Message
            $_sync.Done  = $true
        }
    })
    $handle  = $ps.BeginInvoke()
    $capSync = $fetchSync; $capPS = $ps; $capRS = $rs; $capHandle = $handle
    $capDone = ${function:Complete-MachineFetch}

    $fetchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $fetchTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $fetchTimer.Add_Tick({
        if (-not $capSync.Done) { return }
        $args[0].Stop()
        try { $capPS.EndInvoke($capHandle) } catch {}
        $capRS.Close()
        & $capDone -MachineList @($capSync.Machines) -ErrorText $capSync.Error
    }.GetNewClosure())
    $fetchTimer.Start()
}

# ---- Page checks (Next) ---------------------------------------------------------

function Test-SigninPage {
    $siteCode = if ($controls['CmbSiteCode'].SelectedItem) { $controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    if (-not $siteCode -or -not $controls['TxtSiteDBHost'].Text.Trim() -or -not $controls['TxtSiteDBUser'].Text.Trim() -or -not $controls['PwdSiteDB'].Password) {
        Show-Warning "Fill in Site, Site DB hostname, username, and password." 'Missing Input'; return $false
    }
    $installerUser = $controls['TxtUsername'].Text.Trim()
    $installerPwd  = $controls['PwdUserAccount'].Password
    if (-not $installerUser -or -not $installerPwd) {
        Show-Warning "Enter your domain username and password." 'Credentials Required'; return $false
    }
    if (-not (Test-InstallerCredential -DomainUser $installerUser -Password $installerPwd)) {
        [System.Windows.MessageBox]::Show("Authentication failed for '$installerUser'.", "Authentication Failed", "OK", "Error") | Out-Null
        return $false
    }
    return $true
}

function Test-MachinesPage {
    $cnt   = Get-DOCCount
    $names = @(1..$cnt | ForEach-Object { $cmb = $controls["CmbDOCMachine$_"]; if ($cmb.SelectedItem) { $cmb.SelectedItem.Content } else { '' } })
    if ($names -contains '') { Show-Warning "Pick a machine for every DOC instance."; return $false }
    if (@($names | Sort-Object -Unique).Count -ne $names.Count) { Show-Warning "Each DOC instance needs a different machine."; return $false }
    return $true
}

function Test-DataAppsPage {
    $dataRoot   = $controls['TxtDataRoot'].Text.Trim()
    $activeInst = @(Get-DataAppsSelection -CncCount (Get-DOCCount) | Where-Object { $_.CNCs.Count -gt 0 })
    if (-not $dataRoot) { Show-Warning "Enter the Data Applications local data root."; return $false }
    if ($activeInst.Count -eq 0) { Show-Warning "Tick at least one CNC for an instrument."; return $false }
    $noSource = @($activeInst | Where-Object { -not $_.SourcePath } | ForEach-Object { $_.Type })
    if ($noSource.Count -gt 0) { Show-Warning "Enter a source path for: $($noSource -join ', ')"; return $false }
    return $true
}

# ---- Start the run (Review page -> Start) ---------------------------------------

function Start-ConfigurationRun {
    $type      = Get-ConfigType
    $plan      = Get-PlanSteps
    $runMode   = Get-RunMode
    $Script:SkipSteps = Get-RunSkipSteps
    $Script:StartStep = if ($controls['CmbStartStep'].SelectedItem) { [int]$controls['CmbStartStep'].SelectedItem.Content } else { 1 }
    $runSteps  = @($plan | Where-Object { $_ -notin $Script:SkipSteps -and $_ -ge $Script:StartStep })
    if ($runSteps.Count -eq 0) { Show-Warning "No steps would run. Check the run mode and the start step."; return $false }

    if (2 -in $runSteps -and -not $controls['PwdAPCUser'].Password) {
        Show-Warning "Enter the apcuser (local) password on the Sign in page - TimescaleDB (step 2) needs it." 'Password Required'; return $false
    }
    if (4 -in $runSteps -and -not $controls['PwdMedtronicSU'].Password) {
        Show-Warning "Enter the MedtronicSU password on the Sign in page - deviceWise (step 4) needs it." 'Password Required'; return $false
    }
    $license = $controls['TxtLicense'].Text.Trim()
    if (8 -in $runSteps -and -not $license) {
        Show-Warning "Enter the CNCnetPDM license key or tick 'Use default perpetual license'."; return $false
    }
    if (10 -in $runSteps -and -not (Test-DataAppsPage)) { return $false }
    $chmiPage = 'chmi' -in (Get-WizardPages)
    if (11 -in $runSteps -and $chmiPage -and -not (Test-CHMIPage)) { return $false }

    $docCount = Get-DOCCount
    $docMachineAssignments = @(1..$docCount | ForEach-Object {
        $cmb = $controls["CmbDOCMachine$_"]; if ($cmb.SelectedItem) { $cmb.SelectedItem.Content } else { '' }
    })

    $Script:TestMode    = $runMode -eq 'Test'
    $Script:RunModeName = @{ Full = 'full run'; Reviewed = 'reviewed steps only'; Test = 'test mode'; Verify = 'verification only' }[$runMode]
    $Script:RunManifest = $manifest
    if (-not $Script:TestMode -and $runMode -ne 'Verify') {
        $answer = [System.Windows.MessageBox]::Show(
            "This $($Script:RunModeName) changes the REAL configuration on this VM (steps $($runSteps -join ', ')).`n`nEach file is backed up (.bak) before it is changed. Continue?",
            "Confirm real run", "YesNo", "Warning")
        if ($answer -ne 'Yes') { return $false }
    }

    $Script:AutoState = Get-CurrentState
    # This run's own folder: C:\APC_Config\<type>_<yyyyMMdd-HHmmss>\{Logs,Backups,Reports}
    $runRoot = Join-Path 'C:\APC_Config' ("{0}_{1}" -f $Script:ConfigTypes[$type].Folder, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        foreach ($sub in 'Logs', 'Reports') { New-Item -ItemType Directory -Path (Join-Path $runRoot $sub) -Force -ErrorAction Stop | Out-Null }
    } catch {
        [System.Windows.MessageBox]::Show("Could not create the run folder $runRoot`n$_", "Run folder", "OK", "Error") | Out-Null; return $false
    }
    $Script:AutoState['RunRoot'] = $runRoot
    $Script:AutoState['ConfigType']            = $type
    $Script:AutoState['ConfigReason']          = $Script:ConfigTypes[$type].ReasonIndex
    $Script:AutoState['ConfigReasonOther']     = if ($type -eq 'verify') { $Script:VerifyReasonOther } else { '' }
    $Script:AutoState['ChangeID']              = $controls['TxtChangeID'].Text.Trim()
    $Script:AutoState['CNCMachines']           = @($Global:FetchedMachines)
    $Script:AutoState['DOCMachineAssignments'] = $docMachineAssignments
    $Script:AutoState['DataAppsInstruments']   = @(Get-DataAppsSelection -CncCount $docCount)
    $Script:AutoState['DataAppsLocalRoot']     = $controls['TxtDataRoot'].Text.Trim()
    $Script:AutoState['CNCnetPDMLicense']      = $license
    if ($chmiPage) { $Script:AutoState['800xASettings'] = Get-CHMISettingsState }

    $apcPwd = New-Object System.Security.SecureString
    foreach ($c in $controls['PwdAPCUser'].Password.ToCharArray()) { $apcPwd.AppendChar($c) }
    $suPwd  = New-Object System.Security.SecureString
    foreach ($c in $controls['PwdMedtronicSU'].Password.ToCharArray()) { $suPwd.AppendChar($c) }
    $sdbPwd = New-Object System.Security.SecureString
    foreach ($c in $controls['PwdSiteDB'].Password.ToCharArray()) { $sdbPwd.AppendChar($c) }
    $Script:AutoState['APCUserPassword']     = $apcPwd
    $Script:AutoState['MedtronicSUPassword'] = $suPwd
    $Script:AutoState['SiteDBPassword']      = $sdbPwd

    $runLog = @("$($Script:ConfigTypes[$type].Name) - $($Script:RunModeName): steps $($runSteps -join ', ')", "Run folder: $runRoot")
    switch ($runMode) {
        'Reviewed' { $window.Title = 'APC Configuration Deployment Wizard  [REVIEWED STEPS ONLY]' }
        'Verify'   { $window.Title = 'APC Configuration Deployment Wizard  [VERIFICATION ONLY]' }
        'Test' {
            $sandboxRoot = Join-Path $runRoot 'Sandbox'
            try {
                $sb = New-SandboxManifest -Manifest $manifest -Root $sandboxRoot
            } catch {
                [System.Windows.MessageBox]::Show("Could not create the test sandbox:`n$_", "Test Mode", "OK", "Error") | Out-Null; return $false
            }
            $Script:RunManifest = $sb.Manifest
            $Script:AutoState['SandboxRoot']       = $sandboxRoot
            $Script:AutoState['DataAppsLocalRoot'] = $sb.Manifest.DataApps.LocalDataRoot
            $runLog += "TEST MODE - sandbox: $sandboxRoot"
            $runLog += "  Copied $($sb.Copied.Count) installed file(s) into the sandbox"
            foreach ($miss in $sb.Missing) { $runLog += "  Not found (step will report it): $miss" }
            $window.Title = 'APC Configuration Deployment Wizard  [TEST MODE]'
        }
        default { $window.Title = 'APC Configuration Deployment Wizard' }
    }
    Save-State -State $Script:AutoState

    # Step rows: only the type's steps are shown; mode-skipped and earlier-than-start steps show Skipped
    foreach ($s in $Script:StepDefs) {
        $n = $s.Index
        $controls["RowStep$n"].Visibility = if ($n -in $plan) { 'Visible' } else { 'Collapsed' }
        Set-StepState -Index $n -State $(if ($n -in $runSteps) { 'Pending' } else { 'Skipped' })
    }
    $Script:RunTotal  = $runSteps.Count
    $Script:RunDone   = 0
    $Script:AutoIndex = 0
    $Script:RunState  = 'running'
    $controls['TxtRunTitle'].Text              = 'Running'
    $controls['LogAll'].Text                   = ($runLog -join "`r`n") + "`r`n"
    $controls['TxtReportPath'].Visibility      = 'Collapsed'
    $controls['BtnOpenReport'].Visibility      = 'Collapsed'
    $controls['TxtReportStatus'].Text          = ''
    Update-RunProgress
    return $true
}

# ---- Back / Next ----------------------------------------------------------------

$controls['BtnBack'].Add_Click({
    if ($Script:PageIndex -gt 0) { $Script:PageIndex--; Update-Wizard }
})

$controls['BtnNext'].Add_Click({
    $pages = Get-WizardPages
    switch ($pages[$Script:PageIndex]) {
        'signin' {
            if (Test-SigninPage) { Start-MachineFetch }   # moves on when the machines are loaded
            return
        }
        'scope' {
            if (@(Get-PickedComponents).Count -eq 0) { Show-Warning "Pick at least one component."; return }
        }
        'machines' { if (-not (Test-MachinesPage)) { return } }
        'components' {
            if (-not $controls['TxtLicense'].Text.Trim()) { Show-Warning "Enter the CNCnetPDM license key or tick 'Use default perpetual license'."; return }
        }
        'dataapps' { if (-not (Test-DataAppsPage)) { return } }
        'chmi'     { if (-not (Test-CHMIPage)) { return } }
        'review' {
            if (-not (Start-ConfigurationRun)) { return }
            $Script:PageIndex++
            Update-Wizard
            Run-NextAutoModule
            return
        }
        'verify' { $window.Close(); return }
    }
    $Script:PageIndex++
    Update-Wizard
})

# ---- Re-run buttons ---------------------------------------------------------

foreach ($s in $Script:StepDefs) {
    $controls["BtnRerun$($s.Index)"].Add_Click({
        param($btn)
        if (-not $Script:AutoState -or $Script:RunState -eq 'running') { return }
        $Script:RerunIndex = [int]$btn.Tag
        $mod = $Script:StepDefs | Where-Object { $_.Index -eq $Script:RerunIndex }
        Set-StepState -Index $Script:RerunIndex -State 'Running'
        Add-LogSection -Title "Step $($mod.Index) -- $($mod.Name) (re-run)"
        Start-ModuleInWindow `
            -ModuleFile   $mod.File `
            -FunctionName $mod.Fn `
            -State        $Script:AutoState `
            -LogBox       $controls['LogAll'] `
            -OnDone       {
                param([bool]$ok)
                Set-StepState -Index $Script:RerunIndex -State $(if ($ok) { 'Done' } else { 'Failed' })
                Save-RunLog
                if ($Script:RerunIndex -eq 13) { Update-VerifySummary -LogText $controls['LogAll'].Text }
            }
    })
}

# ---- Verification page: draft checklist -------------------------------------------

function Get-ChecklistReason {
    if ((Get-ConfigType) -ne 'verify') { return $Script:ConfigTypes[(Get-ConfigType)].ReasonIndex }
    foreach ($i in 0..5) { if ($controls["RbReason$i"].IsChecked) { return $i } }
    return 5
}

$controls['BtnGenerateReport'].Add_Click({
    if (-not $Script:AutoState) { Show-Warning "Run the configuration first."; return }
    $reason = Get-ChecklistReason
    $Script:AutoState['ConfigReason']      = $reason
    $Script:AutoState['ConfigReasonOther'] = if ((Get-ConfigType) -eq 'verify' -and $reason -eq 5) { $Script:VerifyReasonOther } else { '' }
    $Script:AutoState['ChangeID']          = $controls['TxtChangeID'].Text.Trim()

    $controls['BtnGenerateReport'].IsEnabled = $false
    $controls['LogReport'].Text             = ''
    $controls['TxtReportStatus'].Text       = 'Running verification and drafting the checklist...'
    $controls['TxtReportStatus'].Foreground = '#4361EE'
    Start-ModuleInWindow `
        -ModuleFile   '13-Verification.ps1' `
        -FunctionName 'Invoke-Verification' `
        -State        $Script:AutoState `
        -LogBox       $controls['LogReport'] `
        -OnDone       {
            param([bool]$ok)
            $controls['BtnGenerateReport'].IsEnabled = $true
            Update-VerifySummary -LogText $controls['LogReport'].Text
            $doc  = $Script:AutoState['VerificationDocPath']
            $html = $Script:AutoState['VerificationReportPath']
            if ($doc -or $html) {
                $controls['TxtReportPath'].Text       = (@("Draft checklist: $doc", "Report: $html") | Where-Object { $_ -notmatch ': $' }) -join "`n"
                $controls['TxtReportPath'].Visibility = 'Visible'
                $controls['BtnOpenReport'].Visibility = 'Visible'
            }
            $controls['TxtReportStatus'].Text       = if ($ok) { 'Draft ready' } else { 'Finished with failed checks - see the draft' }
            $controls['TxtReportStatus'].Foreground = if ($ok) { '#166534' } else { '#D97706' }
        }
})

$controls['BtnOpenReport'].Add_Click({
    $doc = if ($Script:AutoState) { $Script:AutoState['VerificationDocPath'] } else { $null }
    if (-not $doc -or -not (Test-Path $doc)) {
        $reports = if ($Script:AutoState -and $Script:AutoState['RunRoot']) { Join-Path $Script:AutoState['RunRoot'] 'Reports' } else { 'C:\APC_Config\Reports' }
        $doc = Get-ChildItem $reports -Filter 'D01555624_Filled_*.docx' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($doc) { Start-Process $doc }
})

$controls['CmbSiteCode'].SelectedIndex = 0
Update-SiteDBFields
Update-DataAppsDefaults
$controls['CmbSiteCode'].Add_SelectionChanged({ Update-SiteDBFields; Update-DataAppsDefaults; Update-Wizard })
Update-DOCRows
Update-Wizard

try {
    $window.ShowDialog() | Out-Null
} catch {
    # Errors thrown inside WPF event handlers surface here wrapped; report where they really happened
    $rec = $null; $e = $_.Exception
    while ($e) {
        if ($e -is [System.Management.Automation.IContainsErrorRecord] -and $e.ErrorRecord.InvocationInfo -and
            $e.ErrorRecord.InvocationInfo.ScriptLineNumber -gt 0) { $rec = $e.ErrorRecord }
        $e = $e.InnerException
    }
    Write-Host "Wizard error: $($_.Exception.Message)" -ForegroundColor Red
    if ($rec) {
        Write-Host $rec.InvocationInfo.PositionMessage -ForegroundColor Yellow
        Write-Host $rec.ScriptStackTrace -ForegroundColor Yellow
    }
    throw
}
