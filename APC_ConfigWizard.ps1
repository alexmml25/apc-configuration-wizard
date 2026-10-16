#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    APC Configuration Manager - GUI entry point
.DESCRIPTION
    Step-by-step WPF wizard that configures the APC system (D01555607) after installation and
    drafts the D01555624 Configuration Verification Checklist. Same look and behaviour as the APC Installation Manager.
    Pick a configuration type, sign in, fill in the pages that type needs, review, start: Steps 1-12 run one after
    the other and a failed step stops the run (Re-run continues it). Verification (Step 13) runs once when the last
    page opens (Run again), then the draft checklist is created from its results.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:AppName      = 'APC Configuration Manager'
$Script:AppVersion   = '1.0.0.0'   # shown in the header, written to Wizard.log, the state and the report
$Script:RootDir      = $PSScriptRoot
$Script:ModulesDir   = Join-Path $Script:RootDir 'modules'
$Script:ManifestPath = Join-Path $Script:RootDir 'APC_ConfigManifest.json'
# work folder (D:\APC_Config, C: without a D: disk) - set once the manifest and Common.ps1 are loaded below
$Script:ApcRoot      = $null
$Script:StateFile    = $null

function Get-Manifest {
    if (-not (Test-Path $Script:ManifestPath)) {
        [System.Windows.MessageBox]::Show("Manifest not found:`n$Script:ManifestPath", $Script:AppName, "OK", "Error") | Out-Null
        exit 1
    }
    return Get-Content $Script:ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$manifest = Get-Manifest
. (Join-Path $Script:ModulesDir 'Common.ps1')
. (Join-Path $Script:ModulesDir 'ABB800xA.ps1')
. (Join-Path $Script:ModulesDir 'Release.ps1')
$Script:ApcRoot   = Get-ApcRoot $manifest
# Release from the Installation Manager's workbook (APC Releases.xlsx on the deployment share); manifest value without it
$Script:Release   = Get-ApcRelease -Manifest $manifest
$Script:StateFile = Join-Path $Script:ApcRoot '.config_state.json'
$Script:RunManifest = $manifest   # the run's copy, <X>:\Medtronic paths on the install drive
$Script:SkipSteps   = @()

# Step definitions
$StepDefs = @(
    @{ Index =  1; Name = 'Prerequisites';                  File = '01-Prerequisites.ps1';    Fn = 'Invoke-Prerequisites'     },
    @{ Index =  2; Name = 'TimescaleDB Setup';              File = '02-TimescaleDB.ps1';      Fn = 'Invoke-TimescaleDBSetup'  },
    @{ Index =  3; Name = 'SINC Folder Structure';          File = '03-SINCFolders.ps1';      Fn = 'Invoke-SINCFolders'       },
    @{ Index =  4; Name = 'deviceWise Base Platform';       File = '04-DeviceWiseBase.ps1';   Fn = 'Invoke-DeviceWiseBase'    },
    @{ Index =  5; Name = 'deviceWise CHMI Integration';    File = '05-DeviceWiseCHMI.ps1';   Fn = 'Invoke-DeviceWiseCHMI'    },
    @{ Index =  6; Name = 'deviceWise SINC Integration';    File = '06-DeviceWiseSINC.ps1';   Fn = 'Invoke-DeviceWiseSINC'    },
    @{ Index =  7; Name = 'CNCnetPDM Configuration';        File = '07-CNCnetPDM.ps1';        Fn = 'Invoke-CNCnetPDM'   },
    @{ Index =  8; Name = 'deviceWise CNCnetPDM Integration'; File = '08-DeviceWiseCNCPDM.ps1'; Fn = 'Invoke-DeviceWiseCNCPDM' },
    @{ Index =  9; Name = 'DOC XML Configuration';          File = '09-DOCConfig.ps1';        Fn = 'Invoke-DOCConfig'         },
    @{ Index = 10; Name = 'Data Applications Config';       File = '10-DataApps.ps1';         Fn = 'Invoke-DataApps'    },
    @{ Index = 11; Name = 'CHMI / APC UI OPC UA';           File = '11-CHMI.ps1';             Fn = 'Invoke-CHMI'        },
    # Configuration Restore only (shown as "Restore"); runs before Step 12, which then backs up the restored state
    @{ Index = 14; Name = 'Configuration Restore';          File = '14-Restore.ps1';          Fn = 'Invoke-ConfigRestore' },
    @{ Index = 12; Name = 'Application Backup';             File = '12-Backup.ps1';           Fn = 'Invoke-Backup' },
    @{ Index = 13; Name = 'Verification & Report';          File = '13-Verification.ps1';     Fn = 'Invoke-Verification'}
)

# Configuration types = the "Reason for Configuration" boxes of D01555624 rev C (the draft ticks the box of the type,
# Manifest.Checklist.ReasonLabels). Verification replaces "Other" in the wizard: a read-only check; on its last page the
# operator picks which box the draft ticks. Restore and System Update / Import are not built yet (plan step 6).
# Folder = prefix of the run's own folder, <work folder>\<Folder>_<yyyyMMdd-HHmmss> (Logs, Backups, Reports inside).
$Script:ConfigTypes = [ordered]@{
    initial   = @{ Name = 'Initial System Configuration';     Folder = 'InitialConfiguration' }
    restore   = @{ Name = 'Configuration Restore';            Folder = 'ConfigurationRestore' }
    component = @{ Name = 'Component Configuration / Update'; Folder = 'ComponentConfiguration' }
    sysupdate = @{ Name = 'System Update / Import';           Folder = 'SystemUpdate' }
    verify    = @{ Name = 'Verification';                     Folder = 'Verification' }
}
$Script:VerifyReasonOther = 'Verification only (no changes)'
$Script:Dot = [string][char]0x00B7   # middle dot; kept out of the source so Windows PowerShell 5.1 reads the file as plain ASCII

# Components offered for Component Configuration / Update, and the steps each runs
$Script:Components = [ordered]@{
    tsdb = @{ Label = 'TimescaleDB';                                                   Steps = @(2) }
    sinc = @{ Label = 'SINC folders';                                                  Steps = @(3) }
    dw   = @{ Label = 'deviceWise';                                                    Steps = @(4, 5, 6, 8) }
    cnc  = @{ Label = 'CNCnetPDM';                                                     Steps = @(7) }
    doc  = @{ Label = 'DOC';                                                           Steps = @(9) }
    da   = @{ Label = 'Data applications (File Manager, Data Collector, Data Analyzer)'; Steps = @(10) }
    chmi = @{ Label = 'CHMI / APC UI';                                                 Steps = @(11) }
}

$Script:PageLabels = [ordered]@{
    type       = 'Configuration type'
    signin     = 'Sign in & passwords'
    scope      = 'Components'
    restore    = 'Backup to restore'
    machines   = 'Machines & DOC'
    components = 'SINC & CNCnetPDM'
    dataapps   = 'Data applications'
    chmi       = 'CHMI (800xA)'
    review     = 'Review & start'
    run        = 'Configure'
    verify     = 'Verification & report'
}
$Script:PagePanels = @{
    type = 'PageType'; signin = 'PageSignin'; scope = 'PageScope'; restore = 'PageRestore'; machines = 'PageMachines'; components = 'PageComponents'
    dataapps = 'PageDataApps'; chmi = 'PageCHMI'; review = 'PageReview'; run = 'PageRun'; verify = 'PageVerify'
}

$xamlText = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="APC Configuration Manager"
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
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="SegBd" Property="Background" Value="#F1F5F9"/>
                <Setter TargetName="SegCp" Property="TextElement.Foreground" Value="#CBD5E1"/>
                <Setter Property="Cursor" Value="Arrow"/>
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
    <Style x:Key="AmberCard" TargetType="Border">
      <Setter Property="Background"      Value="#FFFBEB"/>
      <Setter Property="BorderBrush"     Value="#FDE68A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius"    Value="8"/>
      <Setter Property="Padding"         Value="16,12"/>
      <Setter Property="Margin"          Value="0,0,0,16"/>
    </Style>
    <Style x:Key="TagChip" TargetType="Border">
      <Setter Property="CornerRadius"      Value="10"/>
      <Setter Property="Padding"           Value="7,1"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
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
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="APC Configuration Manager" FontSize="18" FontWeight="SemiBold" Foreground="Black" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtAppVersion" FontSize="12" Foreground="#64748B" Margin="10,0,0,0" VerticalAlignment="Bottom" Padding="0,0,0,2"/>
        </StackPanel>
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
                       Text="Pick the reason for this configuration. It decides which steps follow and is ticked under Reason for Configuration in the Configuration Verification Checklist (D01555624)."/>
            <UniformGrid Columns="2" Margin="0,0,-12,0">
              <RadioButton x:Name="RbType_initial" Style="{StaticResource TypeCard}" IsChecked="True">
                <StackPanel>
                  <TextBlock Text="Initial System Configuration" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Establishment of APC system configuration following installation." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Full configuration &#x00B7; 12 steps" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_restore" Style="{StaticResource TypeCard}">
                <StackPanel>
                  <TextBlock Text="Configuration Restore" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Restoration of APC configuration from an approved backup." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Choose a backup of this VM &#x00B7; deviceWise, DOC, data applications, CNCnetPDM" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_component" Style="{StaticResource TypeCard}">
                <StackPanel>
                  <TextBlock Text="Component Configuration / Update" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Configuration or modification of one or more APC components or configuration elements within an existing configured APC system (e.g., deviceWise, DOC, Data Applications, CNCnetPDM, CHMI), excluding initial system configuration, configuration restore, and deployment or import of approved configuration packages." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Choose the components &#x00B7; starts from what is on this VM" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbType_sysupdate" Style="{StaticResource TypeCard}" IsEnabled="False">
                <StackPanel>
                  <TextBlock Text="System Update / Import" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Deployment or import of approved configuration packages, including CHMI or APC interface updates." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Not available yet" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8"/>
                </StackPanel>
              </RadioButton>
            </UniformGrid>
            <!-- Verification alone on the last row, centred under the two columns (one card wide) -->
            <Grid Margin="0,0,-12,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <RadioButton x:Name="RbType_verify" Grid.Column="1" Grid.ColumnSpan="2" Style="{StaticResource TypeCard}">
                <StackPanel>
                  <TextBlock Text="Verification" FontSize="14" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Text="Check that the APC system is configured and working, without changing anything. Useful for troubleshooting." TextWrapping="Wrap" FontSize="12" Foreground="#475569" Margin="0,4"/>
                  <TextBlock Text="Read-only &#x00B7; no changes made" FontSize="11" FontWeight="SemiBold" Foreground="#4361EE"/>
                </StackPanel>
              </RadioButton>
            </Grid>
            <Border x:Name="PanelBeforeStart" Style="{StaticResource Card}" BorderBrush="#C7D2FE" Margin="0,4,0,12">
              <StackPanel TextElement.Foreground="#334155">
                <TextBlock Text="Before you start" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,4"/>
                <TextBlock Text="Please have the following ready before proceeding:" Margin="0,0,0,6"/>
                <TextBlock TextWrapping="Wrap" Margin="0,0,0,4">&#x2022; <Run FontWeight="SemiBold" Foreground="#1C2136">Required credentials:</Run> PostgreSQL, apcuser and APC service account passwords.</TextBlock>
                <TextBlock TextWrapping="Wrap" Margin="0,0,0,4">&#x2022; <Run FontWeight="SemiBold" Foreground="#1C2136">Documentation:</Run> Change ID, Document Number and the Installation Verification Record document ID for the Configuration Verification Checklist.</TextBlock>
                <TextBlock TextWrapping="Wrap" Margin="0,0,0,4">&#x2022; <Run FontWeight="SemiBold" Foreground="#1C2136" Text="Configuration time: "/><Run x:Name="RunConfigTime"/></TextBlock>
                <TextBlock TextWrapping="Wrap">&#x2022; <Run FontWeight="SemiBold" Foreground="#1C2136">VM availability:</Run> Do not use the VM for other activities during configuration.</TextBlock>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource AmberCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Text="&#x26A0;" FontSize="16" Foreground="#B45309" Margin="0,0,10,0" VerticalAlignment="Top"/>
                <TextBlock Grid.Column="1" TextWrapping="Wrap" Foreground="#78350F">
                  <Run x:Name="RunWarnTitle" FontWeight="SemiBold"/> <Run x:Name="RunWarnText"/>
                </TextBlock>
              </Grid>
            </Border>
          </StackPanel>

          <!-- ===== SIGN IN & PASSWORDS ===== -->
          <StackPanel x:Name="PageSignin" Visibility="Collapsed">
            <TextBlock Text="Sign in and passwords" Style="{StaticResource PageTitle}"/>
            <TextBlock x:Name="TxtSigninHint" Style="{StaticResource PageHint}"/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Your account" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Username" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtUsername" Grid.Row="0" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="1" Text="Password" Style="{StaticResource Label}"/>
                  <PasswordBox x:Name="PwdUserAccount" Grid.Row="1" Grid.Column="1" Style="{StaticResource Pwd}"/>
                  <TextBlock Grid.Row="2" Text="Site" Style="{StaticResource Label}"/>
                  <ComboBox  x:Name="CmbSiteCode" Grid.Row="2" Grid.Column="1" Style="{StaticResource Combo}" Width="160" HorizontalAlignment="Left"/>
                  <TextBlock Grid.Row="3" Text="Site DB" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                  <TextBlock Grid.Row="3" Grid.Column="1" VerticalAlignment="Center" TextWrapping="Wrap" Foreground="#334155">
                    <Run x:Name="RunSiteDBHost" FontFamily="Consolas" FontSize="12"/> <Run x:Name="RunSiteDBNote" FontSize="12" Foreground="#64748B"/>
                  </TextBlock>
                </Grid>
                <!-- only when the manifest has no Site DB server / user / password for the site -->
                <Grid x:Name="PanelSiteDBEdit" Visibility="Collapsed" Margin="0,12,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Site DB hostname" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtSiteDBHost" Grid.Row="0" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="1" Text="Site DB username" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtSiteDBUser" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="2" Text="Site DB password" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                  <PasswordBox x:Name="PwdSiteDB" Grid.Row="2" Grid.Column="1" Style="{StaticResource Pwd}" Margin="0"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border x:Name="PanelPasswords" Style="{StaticResource AmberCard}" Padding="16">
              <StackPanel>
                <TextBlock Text="Configuration passwords" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,2"/>
                <TextBlock FontSize="12" Foreground="#92400E" TextWrapping="Wrap" Margin="0,0,0,12"
                           Text="Used only during the configuration and never saved. Checked when you press Next."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="apcuser (local)" Style="{StaticResource Label}"
                             ToolTip="Password of the local TimescaleDB apcuser role (the standard APC password). Step 2 creates the role with it."/>
                  <PasswordBox x:Name="PwdAPCUser" Grid.Row="0" Grid.Column="1" Style="{StaticResource Pwd}"/>
                  <TextBlock Grid.Row="1" Text="PostgreSQL" Style="{StaticResource Label}"
                             ToolTip="Password of the local PostgreSQL superuser postgres, set at installation. Step 2 logs in with it."/>
                  <PasswordBox x:Name="PwdPostgres" Grid.Row="1" Grid.Column="1" Style="{StaticResource Pwd}"/>
                  <TextBlock x:Name="TxtSvcAccountLabel" Grid.Row="2" Text="SVC-APC" Style="{StaticResource Label}" Margin="0,0,12,0"
                             ToolTip="Password of the site service account. Step 11 signs in to 800xA OPC UA Connect with it to update the certificates."/>
                  <PasswordBox x:Name="PwdSvcAccount" Grid.Row="2" Grid.Column="1" Style="{StaticResource Pwd}" Margin="0"/>
                </Grid>
              </StackPanel>
            </Border>
            <TextBlock x:Name="TxtProceedStatus" FontSize="12" Foreground="#64748B" TextWrapping="Wrap"/>
          </StackPanel>

          <!-- ===== COMPONENTS (component configuration / update) ===== -->
          <StackPanel x:Name="PageScope" Visibility="Collapsed">
            <TextBlock Text="Which components?" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="The next pages are filled with what is configured on this VM now (site defaults where a component is not set up yet). Only the selected components are touched; everything else is left as it is."/>
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
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Steps 4-6, 8" FontSize="12" Foreground="#64748B"/>
                    <CheckBox x:Name="ChkComp_dw" Content="deviceWise" FontWeight="SemiBold" VerticalContentAlignment="Center"/></DockPanel>
                </Border>
                <Border BorderBrush="#F1F5F9" BorderThickness="0,0,0,1" Padding="0,8">
                  <DockPanel><TextBlock DockPanel.Dock="Right" Text="Step 7" FontSize="12" Foreground="#64748B"/>
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
            <TextBlock Style="{StaticResource PageHint}" Text="Step 1 (prerequisites) and Step 12 (backup) always run. Verification runs on the last page."/>
          </StackPanel>

          <!-- ===== BACKUP TO RESTORE (Configuration Restore) ===== -->
          <StackPanel x:Name="PageRestore" Visibility="Collapsed">
            <TextBlock Text="Backup to restore" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="Choose the approved backup: a run folder of this VM (or its Backups folder), for example a copy from the site backup location. Only this VM's own backups of this APC release can be restored. What is replaced is saved first in this run's Backups folder."/>
            <Border Style="{StaticResource Card}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="TxtRestoreFolder" Style="{StaticResource Input}" Margin="0" FontFamily="Consolas" FontSize="12"/>
                <Button x:Name="BtnRestoreBrowse" Grid.Column="1" Style="{StaticResource SecondaryBtn}" Content="Browse..." Margin="8,0,0,0" Padding="14,6"/>
              </Grid>
            </Border>
            <Border x:Name="PanelRestoreInfo" Style="{StaticResource Card}" Padding="16,12" Visibility="Collapsed">
              <StackPanel>
                <StackPanel x:Name="PanelRestoreRows"/>
                <TextBlock Text="Restore" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,8,0,8"/>
                <CheckBox x:Name="ChkRestore_dw"  Content="deviceWise (projects, devices, users, OPC UA server and certificates)" Margin="0,0,0,6"/>
                <CheckBox x:Name="ChkRestore_doc" Content="DOC and data applications (DOC-n, File Manager, Data Collector, Data Analyzer folders)" Margin="0,0,0,6"/>
                <CheckBox x:Name="ChkRestore_cnc" Content="CNCnetPDM (configuration, machine files and drivers)"/>
                <TextBlock FontSize="11" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,8,0,0" Text="The APC UI (800xA) backup is not restored here."/>
              </StackPanel>
            </Border>
            <Border x:Name="PanelRestoreProblem" Margin="0,0,0,16" Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="8" Padding="16,12" Visibility="Collapsed">
              <TextBlock x:Name="TxtRestoreProblem" TextWrapping="Wrap" Foreground="#991B1B"/>
            </Border>
          </StackPanel>

          <!-- ===== MACHINES & DOC ===== -->
          <StackPanel x:Name="PageMachines" Visibility="Collapsed">
            <TextBlock Text="Machines and DOC instances" Style="{StaticResource PageTitle}"/>
            <TextBlock x:Name="TxtMachineCount" Style="{StaticResource PageHint}"
                       Text="DOC n = CNC n; only assigned machines are configured."/>
            <!-- Component Configuration / Update: what this VM has now -->
            <Border x:Name="PanelMachTags" Style="{StaticResource Card}" Padding="14,10" BorderBrush="#C7D2FE" Background="#F8FAFF" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="&#x24D8;" FontSize="16" Foreground="#4361EE" Margin="0,0,10,0" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" TextWrapping="Wrap" Foreground="#334155" VerticalAlignment="Center">Filled from this VM (DOC and CNCnetPDM configuration, read at sign-in). <Run Foreground="#3451D1" FontWeight="SemiBold">Current</Run> is configured now, <Run Foreground="#166534" FontWeight="SemiBold">New</Run> is not configured yet, <Run Foreground="#B45309" FontWeight="SemiBold">Changed</Run> is your edit and is listed on Review.</TextBlock>
                <Button x:Name="BtnUndoMach" Grid.Column="2" Style="{StaticResource SecondaryBtn}" Content="Undo my changes" Padding="12,6" Margin="12,0,0,0" VerticalAlignment="Center"/>
              </Grid>
            </Border>
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
              <TextBlock x:Name="TxtDocNow" FontSize="12" Foreground="#64748B" VerticalAlignment="Center" Margin="12,0,8,0"/>
              <Border x:Name="BdDocCountTag" Style="{StaticResource TagChip}"><TextBlock x:Name="TxtDocCountTag" FontSize="11" FontWeight="SemiBold"/></Border>
            </StackPanel>
            <Border Style="{StaticResource Card}" Padding="16,12">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition x:Name="ColDOCTagHead" Width="86"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="CNC"       Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="1" Text="MACHINE"   Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="2" Text="FAMILY"    Style="{StaticResource ColHead}" Margin="12,0,0,8"/>
                  <TextBlock Grid.Column="3" Text="DEVICE NR" Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="4" Text="DLL"       Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="5" Text="ON THIS VM" Style="{StaticResource ColHead}" Margin="8,0,0,8"/>
                </Grid>
                <Grid x:Name="GridDOCRow1">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition x:Name="ColDOCTag1" Width="86"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC1" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbDOCMachine1" Grid.Column="1" Style="{StaticResource Combo}"/>
                  <TextBlock x:Name="TxtDOCFam1" Grid.Column="2" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="12,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDev1" Grid.Column="3" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDll1" Grid.Column="4" FontFamily="Consolas" FontSize="12" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <Border x:Name="BdDOCTag1" Grid.Column="5" Style="{StaticResource TagChip}" Margin="8,0,0,10"><TextBlock x:Name="TxtDOCTag1" FontSize="11" FontWeight="SemiBold"/></Border>
                </Grid>
                <Grid x:Name="GridDOCRow2">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition x:Name="ColDOCTag2" Width="86"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC2" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbDOCMachine2" Grid.Column="1" Style="{StaticResource Combo}"/>
                  <TextBlock x:Name="TxtDOCFam2" Grid.Column="2" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="12,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDev2" Grid.Column="3" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDll2" Grid.Column="4" FontFamily="Consolas" FontSize="12" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <Border x:Name="BdDOCTag2" Grid.Column="5" Style="{StaticResource TagChip}" Margin="8,0,0,10"><TextBlock x:Name="TxtDOCTag2" FontSize="11" FontWeight="SemiBold"/></Border>
                </Grid>
                <Grid x:Name="GridDOCRow3">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition x:Name="ColDOCTag3" Width="86"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CNC3" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <ComboBox x:Name="CmbDOCMachine3" Grid.Column="1" Style="{StaticResource Combo}"/>
                  <TextBlock x:Name="TxtDOCFam3" Grid.Column="2" FontSize="12" Foreground="#475569" VerticalAlignment="Center" Margin="12,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDev3" Grid.Column="3" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtDOCDll3" Grid.Column="4" FontFamily="Consolas" FontSize="12" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <Border x:Name="BdDOCTag3" Grid.Column="5" Style="{StaticResource TagChip}" Margin="8,0,0,10"><TextBlock x:Name="TxtDOCTag3" FontSize="11" FontWeight="SemiBold"/></Border>
                </Grid>
                <StackPanel x:Name="PanelDroppedRows"/>
              </StackPanel>
            </Border>
            <Expander x:Name="ExpDOCTimes" Header="Advanced: DOC timeouts" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,16">
              <Border Style="{StaticResource Card}" Margin="0,8,0,0">
                <StackPanel TextElement.FontWeight="Normal">
                  <TextBlock Style="{StaticResource PageHint}" Margin="0,0,0,10"
                             Text="Current values from this VM's DOC files. A changed value is written to every DOC instance; the old file is backed up."/>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="110"/><ColumnDefinition Width="120"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Text="SETTING" Style="{StaticResource ColHead}"/>
                    <TextBlock Grid.Column="1" Text="SECONDS" Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Row="1" Text="Wait for all measurement results of a part" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,8"/>
                  <TextBox x:Name="TxtDOCTimeInsp" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas" Margin="0,0,0,8"/>
                  <TextBlock x:Name="TxtDOCTimeNoteInsp" Grid.Row="1" Grid.Column="2" FontSize="12" VerticalAlignment="Center" Margin="12,0,0,8"/>
                  <TextBlock Grid.Row="2" Text="Wait for all offset calculations" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,8"/>
                  <TextBox x:Name="TxtDOCTimeCalc" Grid.Row="2" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas" Margin="0,0,0,8"/>
                  <TextBlock x:Name="TxtDOCTimeNoteCalc" Grid.Row="2" Grid.Column="2" FontSize="12" VerticalAlignment="Center" Margin="12,0,0,8"/>
                  <TextBlock Grid.Row="3" Text="Wait for the operator to respond" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,8"/>
                  <TextBox x:Name="TxtDOCTimeOper" Grid.Row="3" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas" Margin="0,0,0,8"/>
                  <TextBlock x:Name="TxtDOCTimeNoteOper" Grid.Row="3" Grid.Column="2" FontSize="12" VerticalAlignment="Center" Margin="12,0,0,8"/>
                  </Grid>
                </StackPanel>
              </Border>
            </Expander>
          </StackPanel>

          <!-- ===== SINC & CNCnetPDM ===== -->
          <StackPanel x:Name="PageComponents" Visibility="Collapsed">
            <TextBlock Text="SINC and CNCnetPDM" Style="{StaticResource PageTitle}" Margin="0,0,0,16"/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="SINC" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Text="Alert email" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                  <TextBox x:Name="TxtSINCEmail" Grid.Column="1" Style="{StaticResource Input}" Margin="0" MaxLength="128"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" FontSize="12" Foreground="#64748B" TextWrapping="Wrap" Margin="0,6,0,0"
                             Text="Who gets an e-mail when SINC has a problem, for example a DOC offset file that could not be sent to the CNC. Use a distribution list or the engineers for this cell. Separate addresses with ; (128 characters at most)."/>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="CNCnetPDM" Style="{StaticResource CardTitle}"/>
                <CheckBox x:Name="ChkDefaultLicense" Content="Use default perpetual license" IsChecked="True" Margin="160,0,0,10"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
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
                       Text="Each measurement instrument saves a results file. File Manager picks it up and checks it belongs to the part running on the CNC; Data Collector saves it to the APC database."/>
            <Expander Header="Help with this page" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,16">
              <Border Style="{StaticResource Card}" Margin="0,8,0,0">
                <Grid TextElement.FontWeight="Normal" TextElement.FontSize="12" TextElement.Foreground="#334155">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Files per part" FontWeight="SemiBold" Margin="0,0,12,8"/>
                  <TextBlock Grid.Row="0" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,8" Text="How many measurement files one part produces on this instrument. Contracer usually makes 3 (one per measurement), so it gets CONTRACER1-3. Each one is set up separately in File Manager and Data Collector. BENCH is always 1."/>
                  <TextBlock Grid.Row="1" Text="Measures parts from" FontWeight="SemiBold" Margin="0,0,12,8"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,8" Text="Tick each CNC whose parts go to this instrument. No tick = this instrument is not set up."/>
                  <TextBlock Grid.Row="2" Text="Results folder (shared)" FontWeight="SemiBold" Margin="0,0,12,8"/>
                  <TextBlock Grid.Row="2" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,8" Text="The shared folder the instrument saves its CSV files to. File Manager watches it."/>
                  <TextBlock Grid.Row="3" Text="Error folder" FontWeight="SemiBold" Margin="0,0,12,8"/>
                  <TextBlock Grid.Row="3" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,8" Text="A file that does not match the part, lot or sample on the CNC is moved here so someone can check it. Blank = a DoneError folder on this VM."/>
                  <TextBlock Grid.Row="4" Text="MES copy folder" FontWeight="SemiBold" Margin="0,0,12,0"/>
                  <TextBlock Grid.Row="4" Grid.Column="1" TextWrapping="Wrap" Text="Data Collector puts a copy of each result here for MES. Blank = no copy."/>
                </Grid>
              </Border>
            </Expander>
            <Border Style="{StaticResource Card}" Padding="16,12,16,4">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="130"/><ColumnDefinition Width="146"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="MEASUREMENT INSTRUMENT" Style="{StaticResource ColHead}" TextWrapping="Wrap" ToolTip="The instrument that measures the parts"/>
                  <TextBlock Grid.Column="1" Text="FILES PER PART" Style="{StaticResource ColHead}" ToolTip="How many measurement files one part produces on this instrument"/>
                  <TextBlock Grid.Column="2" Text="MEASURES PARTS FROM" Style="{StaticResource ColHead}" Margin="12,0,0,8" MinWidth="190" ToolTip="The CNCs whose parts go to this instrument"/>
                  <TextBlock Grid.Column="3" Text="RESULTS FOLDER (SHARED)" Style="{StaticResource ColHead}" ToolTip="Shared folder the instrument saves its CSV files to"/>
                </Grid>
                <!--DATAAPPS_INSTRUMENTS-->
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ===== CHMI (800xA) ===== -->
          <StackPanel x:Name="PageCHMI" Visibility="Collapsed">
            <TextBlock Text="CHMI (800xA)" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}"
                       Text="800xA (CHMI) settings for each cell. The current values are read from 800xA; only changed values are written, and every change is logged."/>
            <Border Style="{StaticResource Card}" Padding="16,12,16,6">
              <StackPanel>
                <TextBlock Text="Verification trigger" Style="{StaticResource CardTitle}" Margin="0,0,0,2"/>
                <TextBlock Style="{StaticResource PageHint}" Margin="0,0,0,10" Text="When a verification sample is requested. Button: only when the operator presses the button. Both: on the button or at a shift change."/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="200"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="CNC"     Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="1" Text="MACHINE" Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="2" Text="CELL"    Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="3" Text="IN 800xA" Style="{StaticResource ColHead}"/>
                  <TextBlock Grid.Column="4" Text="SET TO" Style="{StaticResource ColHead}"/>
                </Grid>
                <Grid x:Name="GridCHMIRow1">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="200"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/>
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
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="200"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/>
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
                    <ColumnDefinition Width="60"/><ColumnDefinition Width="200"/><ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/>
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
                <TextBlock Style="{StaticResource PageHint}" Margin="0,0,0,10" Text="Folders for the inspection CSV files, the same for every cell. Filled in for you. Leave them as they are unless told otherwise."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="180"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                  <TextBlock Text="BENCH sample CSV folder" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TxtCHMIBench" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas"/>
                  <TextBlock Grid.Row="1" Text="100% inspection CSV folder" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TxtCHMIPct" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}" FontFamily="Consolas"/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ===== REVIEW & START ===== -->
          <StackPanel x:Name="PageReview" Visibility="Collapsed">
            <TextBlock Text="Review and start" Style="{StaticResource PageTitle}"/>
            <TextBlock Style="{StaticResource PageHint}" Text="Review the summary before starting. You cannot go back once the configuration starts."/>
            <Border Style="{StaticResource Card}" Padding="16,12">
              <StackPanel x:Name="PanelSummary"/>
            </Border>
            <Border x:Name="PanelChanges" Style="{StaticResource Card}" Padding="16,12" Visibility="Collapsed">
              <StackPanel>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Text="What changes on this VM" FontWeight="SemiBold" Foreground="#1C2136"/>
                  <TextBlock Grid.Column="1" Text="Compared with what is configured now" FontSize="12" Foreground="#64748B"/>
                </Grid>
                <StackPanel x:Name="PanelChangeRows"/>
                <TextBlock Style="{StaticResource PageHint}" Margin="0,8,0,0" Text="Everything not listed is kept as it is on this VM."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource AmberCard}">
              <StackPanel>
                <TextBlock Text="While it runs" FontWeight="SemiBold" Foreground="#92400E" Margin="0,0,0,6"/>
                <TextBlock x:Name="TxtWhileRuns" FontSize="12" Foreground="#78350F" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ===== CONFIGURE ===== -->
          <StackPanel x:Name="PageRun" Visibility="Collapsed">
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="TxtRunTitle" Text="Configuring" Style="{StaticResource PageTitle}"/>
              <TextBlock x:Name="TxtProgressLabel" Grid.Column="1" Text="0 / 12 steps" FontSize="12" Foreground="#64748B" VerticalAlignment="Center"/>
            </Grid>
            <ProgressBar x:Name="BarOverall" Height="8" Minimum="0" Maximum="12" Value="0" Margin="0,0,0,12"
                         Foreground="#4361EE" Background="#E2E8F0" BorderThickness="0"/>
            <Border x:Name="PanelFail" Margin="0,0,0,16" Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="8" Padding="16,14" Visibility="Collapsed">
              <StackPanel>
                <Grid Margin="0,0,0,10">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Border Width="20" Height="20" CornerRadius="10" Background="#DC2626" Margin="0,0,10,0" VerticalAlignment="Top">
                    <TextBlock Text="&#x2715;" Foreground="White" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel Grid.Column="1">
                    <TextBlock x:Name="TxtFailTitle" FontWeight="SemiBold" Foreground="#991B1B" TextWrapping="Wrap"/>
                    <TextBlock FontSize="12" Foreground="#7F1D1D" TextWrapping="Wrap" Margin="0,2,0,0"
                               Text="Resolve the error shown in the log, then re-run the step. The remaining steps continue after it passes."/>
                  </StackPanel>
                </Grid>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                  <Button x:Name="BtnFailRerun" Style="{StaticResource PrimaryBtn}" Background="#DC2626" Content="Re-run step"/>
                  <Button x:Name="BtnOpenLog" Style="{StaticResource SecondaryBtn}" Content="Open log" Margin="8,0,0,0"/>
                </StackPanel>
                <TextBlock x:Name="TxtSupport" FontSize="12" Foreground="#7F1D1D" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Padding="14,4">
              <StackPanel>
                <!--STEP_ROWS-->
              </StackPanel>
            </Border>
            <Border x:Name="PanelRunDone" Margin="0,0,0,16" Background="#F0FDF4" BorderBrush="#BBF7D0" BorderThickness="1" CornerRadius="8" Padding="16,12" Visibility="Collapsed">
              <TextBlock TextWrapping="Wrap" Foreground="#166534"><Bold>Configuration complete.</Bold> Continue to verification and the draft checklist.</TextBlock>
            </Border>
            <Expander x:Name="ExpRunLog" Header="Show log" Foreground="#4361EE">
              <TextBox x:Name="LogAll" Style="{StaticResource LogBox}" Height="220" Margin="0,8,0,0"/>
            </Expander>
            <TextBlock x:Name="TxtRunFolder" FontSize="12" Foreground="#64748B" TextWrapping="Wrap" Margin="0,10,0,0"/>
          </StackPanel>

          <!-- ===== VERIFICATION & REPORT ===== -->
          <StackPanel x:Name="PageVerify" Visibility="Collapsed">
            <TextBlock Text="Verification and report" Style="{StaticResource PageTitle}"/>
            <TextBlock x:Name="TxtReportHint" Style="{StaticResource PageHint}"/>
            <Border x:Name="PanelVmRead" Style="{StaticResource Card}" Padding="16,12" Visibility="Collapsed">
              <StackPanel>
                <TextBlock Text="Read from this VM" FontWeight="SemiBold" Foreground="#1C2136"/>
                <TextBlock Style="{StaticResource PageHint}" Margin="0,2,0,10" Text="DOC instances and their machines, from the DOC and CNCnetPDM configuration on this VM. Nothing to enter."/>
                <Grid x:Name="GridVmRows">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid Margin="0,0,0,12">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Verification results" FontWeight="SemiBold" Foreground="#1C2136" VerticalAlignment="Center"/>
                  <TextBlock x:Name="TxtVerifyStatus" Grid.Column="1" FontSize="12" Foreground="#64748B" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <Button x:Name="BtnRunVerification" Grid.Column="2" Style="{StaticResource SecondaryBtn}" Content="Run again" Padding="14,6"/>
                </Grid>
                <UniformGrid Columns="4" Margin="0,0,-12,0">
                  <Border Background="#F0FDF4" BorderBrush="#BBF7D0" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,12,0">
                    <StackPanel><TextBlock x:Name="TxtPassCount" Text="-" FontSize="22" FontWeight="Bold" Foreground="#166534"/><TextBlock Text="Passed" FontSize="12" Foreground="#166534"/></StackPanel>
                  </Border>
                  <Border Background="#FFFBEB" BorderBrush="#FDE68A" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,12,0">
                    <StackPanel><TextBlock x:Name="TxtWarnCount" Text="-" FontSize="22" FontWeight="Bold" Foreground="#92400E"/><TextBlock Text="Warnings" FontSize="12" Foreground="#92400E"/></StackPanel>
                  </Border>
                  <Border Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,12,0">
                    <StackPanel><TextBlock x:Name="TxtFailCount" Text="-" FontSize="22" FontWeight="Bold" Foreground="#991B1B"/><TextBlock Text="Failed" FontSize="12" Foreground="#991B1B"/></StackPanel>
                  </Border>
                  <Border Background="#F8FAFC" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,12,0">
                    <StackPanel><TextBlock x:Name="TxtManualCount" Text="-" FontSize="22" FontWeight="Bold" Foreground="#334155"/><TextBlock Text="Manual (blank in the draft)" FontSize="12" Foreground="#334155" TextWrapping="Wrap"/></StackPanel>
                  </Border>
                </UniformGrid>
                <Expander Header="Show details" Foreground="#4361EE" Margin="0,10,0,0">
                  <TextBox x:Name="LogVerification" Style="{StaticResource LogBox}" Height="160" Margin="0,8,0,0"/>
                </Expander>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Checklist details" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Text="Reason for configuration" Style="{StaticResource Label}" VerticalAlignment="Top"/>
                  <TextBlock x:Name="TxtReason" Grid.Column="1" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,10"/>
                  <UniformGrid x:Name="PanelReason" Grid.Column="1" Columns="2" Margin="0,0,0,10" Visibility="Collapsed">
                    <RadioButton x:Name="RbReason_initial"   GroupName="Reason" Content="Initial System Configuration"     Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason_restore"   GroupName="Reason" Content="Configuration Restore"            Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason_component" GroupName="Reason" Content="Component Configuration / Update" Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason_sysupdate" GroupName="Reason" Content="System Update / Import"           Margin="0,0,12,6"/>
                    <RadioButton x:Name="RbReason_verify"    GroupName="Reason" Content="Other: Verification only (no changes)" IsChecked="True" Margin="0,0,12,6"/>
                  </UniformGrid>
                  <TextBlock Grid.Row="1" Text="Change ID" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TxtChangeID" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="2" Text="Document number" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TxtDocNumber" Grid.Row="2" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="3" Text="Installation Verification Record (D01555616) document ID" Style="{StaticResource Label}" TextWrapping="Wrap"/>
                  <TextBox x:Name="TxtIVRDocId" Grid.Row="3" Grid.Column="1" Style="{StaticResource Input}" VerticalAlignment="Center"/>
                  <TextBlock Grid.Row="4" Text="IT ticket (firewall rules)" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TxtITTicket" Grid.Row="4" Grid.Column="1" Style="{StaticResource Input}" Margin="0,0,0,4"/>
                  <TextBlock Grid.Row="5" Grid.Column="1" Text="All four are added to the draft checklist (D01555624 rev C)." FontSize="11" Foreground="#94A3B8"/>
                </Grid>
              </StackPanel>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <Button x:Name="BtnGenerateReport" Style="{StaticResource PrimaryBtn}" Content="Create draft checklist"/>
              <Button x:Name="BtnOpenReport" Style="{StaticResource SecondaryBtn}" Content="Open draft" Margin="8,0,0,0" IsEnabled="False"/>
              <TextBlock x:Name="TxtReportStatus" VerticalAlignment="Center" Margin="12,0,0,0" FontSize="12" Foreground="#64748B"/>
            </StackPanel>
            <TextBlock x:Name="TxtReportPath" Margin="0,0,0,2" Foreground="#166534" FontSize="12" Visibility="Collapsed" TextWrapping="Wrap"/>
            <TextBlock x:Name="TxtReportMail" Margin="0,0,0,10" Foreground="#64748B" FontSize="12" Visibility="Collapsed" TextWrapping="Wrap"/>
            <Expander Header="Show log" Foreground="#4361EE">
              <TextBox x:Name="LogReport" Style="{StaticResource LogBox}" Height="160" Margin="0,8,0,0"/>
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

# Data Applications instrument rows (one block per manifest instrument type). Files per part = 1 | 2 | 3 segments
# (BENCH: always 1); the instrument names it gives (CMM1, CONTRACER1..3) show on hover.
$instFrag = foreach ($inst in $manifest.DataApps.Instruments) {
    $t     = $inst.Type
    $segs  = (1..3 | ForEach-Object {
        $off = if ($_ -gt [int]$inst.MaxCount -or ($t -eq 'BENCH' -and $_ -gt 1)) { ' IsEnabled="False"' } else { '' }
        $div = if ($_ -gt 1) { '<Border Width="1" Background="#CBD5E1"/>' } else { '' }
        "$div<RadioButton x:Name=`"RbFpp_${t}_$_`" GroupName=`"Fpp_$t`" Style=`"{StaticResource SegBtn}`" Content=`"$_`" Tag=`"$t`"$off/>"
    }) -join ''
    $chks  = (1..3 | ForEach-Object { "<CheckBox x:Name=`"ChkInst_${t}_$_`" Content=`"CNC$_`" VerticalAlignment=`"Center`" Margin=`"0,0,12,0`"/>" }) -join ''
    @"
                <Border BorderBrush="#F1F5F9" BorderThickness="0,1,0,0" Padding="0,10">
                  <StackPanel>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="130"/><ColumnDefinition Width="146"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Text="$t" FontWeight="SemiBold" Foreground="#1C2136" VerticalAlignment="Center"/>
                      <Border x:Name="BdFpp_$t" Grid.Column="1" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="6" ClipToBounds="True" HorizontalAlignment="Left" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">$segs</StackPanel>
                      </Border>
                      <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="12,0,0,0" MinWidth="190">$chks</StackPanel>
                      <TextBox x:Name="TxtInstSrc_$t" Grid.Column="3" Style="{StaticResource Input}" Margin="0" FontFamily="Consolas" FontSize="12"
                               ToolTip="Shared folder the $t saves its CSV files to (File Manager watches it)"/>
                      <Button x:Name="BtnInstMore_$t" Grid.Column="4" Style="{StaticResource SecondaryBtn}" Content="More" Tag="$t"
                              Padding="10,5" FontSize="12" Margin="8,0,0,0"/>
                    </Grid>
                    <Grid x:Name="PanelInstMore_$t" Visibility="Collapsed" Margin="0,10,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Text="Error folder" Style="{StaticResource Label}"/>
                      <TextBox   Grid.Row="0" Grid.Column="1" x:Name="TxtInstErr_$t" Style="{StaticResource Input}" FontFamily="Consolas" FontSize="12"
                                 ToolTip="Blank = DoneError folder on this VM"/>
                      <TextBlock Grid.Row="1" Text="MES copy folder" Style="{StaticResource Label}" Margin="0,0,12,0"/>
                      <TextBox   Grid.Row="1" Grid.Column="1" x:Name="TxtInstBc_$t" Style="{StaticResource Input}" Margin="0" FontFamily="Consolas" FontSize="12"
                                 ToolTip="Blank = no copy"/>
                    </Grid>
                  </StackPanel>
                </Border>
"@
}

# Configure page step rows (Steps 1-12)
$stepFrag = foreach ($s in ($StepDefs | Where-Object { $_.Index -ne 13 })) {   # Step 13 runs on the last page
    $n    = $s.Index
    $name = [System.Security.SecurityElement]::Escape($s.Name)
    $num  = if ($n -eq 14) { 'Restore' } else { "Step $n" }
    $line = if ($n -ne 12) { '0,0,0,1' } else { '0' }
    @"
                <Border x:Name="RowStep$n" BorderBrush="#F1F5F9" BorderThickness="$line" Padding="0,5">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="22"/><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="TxtStep${n}Icon" Text="o" FontSize="14" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="$num" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
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

function Add-PasswordReveal {
    # Eye inside the right edge of a PasswordBox (like Windows sign-in): click to switch the dots to
    # the typed letters and back. The PasswordBox stays the control the code reads (.Password /
    # .SecurePassword); the plain TextBox only holds text while revealed and is cleared when hidden.
    param([System.Windows.Controls.PasswordBox]$Pwd)
    $parent = $Pwd.Parent
    $idx    = $parent.Children.IndexOf($Pwd)
    $wrap   = New-Object System.Windows.Controls.Grid
    $wrap.Margin = $Pwd.Margin
    [System.Windows.Controls.Grid]::SetRow($wrap, [System.Windows.Controls.Grid]::GetRow($Pwd))
    [System.Windows.Controls.Grid]::SetColumn($wrap, [System.Windows.Controls.Grid]::GetColumn($Pwd))
    $parent.Children.RemoveAt($idx)

    # Inside the wrapper everything shares one cell; reset the outer grid's row/column
    [System.Windows.Controls.Grid]::SetRow($Pwd, 0)
    [System.Windows.Controls.Grid]::SetColumn($Pwd, 0)
    $Pwd.Margin = New-Object System.Windows.Thickness 0
    $pad = $Pwd.Padding
    $Pwd.Padding = New-Object System.Windows.Thickness $pad.Left, $pad.Top, 30, $pad.Bottom   # room for the eye

    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Padding         = $Pwd.Padding
    $tb.BorderBrush     = $Pwd.BorderBrush
    $tb.BorderThickness = $Pwd.BorderThickness
    $tb.VerticalContentAlignment = 'Center'
    $tb.Visibility      = 'Collapsed'

    # Flat eye button (no button chrome), drawn over the right end of the box
    $btn = [System.Windows.Markup.XamlReader]::Parse(@'
<ToggleButton xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              Width="30" HorizontalAlignment="Right" Margin="0,1,1,1" Cursor="Hand" Focusable="False"
              ToolTip="Show password" Foreground="#64748B">
  <ToggleButton.Template>
    <ControlTemplate TargetType="ToggleButton">
      <Border Background="Transparent">
        <Grid Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <!-- Slash drawn over the eye while revealed (the eye-slash glyph is missing on Server 2022) -->
          <Path x:Name="Slash" Data="M2,14 L14,2" Stroke="{TemplateBinding Foreground}" StrokeThickness="1.5" Visibility="Collapsed"/>
        </Grid>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Slash" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#1C2136"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </ToggleButton.Template>
  <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" Text="&#xE7B3;"/>
</ToggleButton>
'@)
    $bind = New-Object System.Windows.Data.Binding 'IsEnabled'
    $bind.Source = $Pwd
    $null = $btn.SetBinding([System.Windows.UIElement]::IsEnabledProperty, $bind)

    $wrap.Children.Add($Pwd) | Out-Null
    $wrap.Children.Add($tb)  | Out-Null
    $wrap.Children.Add($btn) | Out-Null
    $parent.Children.Insert($idx, $wrap)

    # References travel in Tag (no closures needed)
    $tb.Tag  = $Pwd
    $Pwd.Tag = $tb
    $btn.Tag = @($Pwd, $tb)
    $btn.Add_Checked({
        param($s, $e)
        $p, $t = $s.Tag
        $t.Text = $p.Password
        $t.Visibility = 'Visible'; $p.Visibility = 'Collapsed'
        $s.ToolTip = 'Hide password'
        $t.Focus() | Out-Null; $t.CaretIndex = $t.Text.Length
    })
    $btn.Add_Unchecked({
        param($s, $e)
        $p, $t = $s.Tag
        $p.Password = $t.Text
        $t.Visibility = 'Collapsed'; $p.Visibility = 'Visible'   # collapse before clearing (TextChanged)
        $t.Clear()
        $s.ToolTip = 'Show password'
        $p.Focus() | Out-Null
    })
    $tb.Add_TextChanged({
        param($s, $e)
        if ($s.Visibility -eq 'Visible' -and $s.Tag.Password -ne $s.Text) { $s.Tag.Password = $s.Text }
    })
    $Pwd.Add_PasswordChanged({
        param($s, $e)   # e.g. .Clear() from code while revealed
        if ($s.Tag.Visibility -eq 'Visible' -and $s.Tag.Text -ne $s.Password) { $s.Tag.Text = $s.Password }
    })
}

foreach ($n in 'PwdUserAccount', 'PwdAPCUser', 'PwdPostgres', 'PwdSvcAccount', 'PwdSiteDB') { Add-PasswordReveal -Pwd $controls[$n] }

# ---- Start-up values ------------------------------------------------------------

$window.Title = $Script:AppName
$controls['TxtAppVersion'].Text = "v$Script:AppVersion"
$controls['RunConfigTime'].Text = if ($manifest.APC.PSObject.Properties['ExpectedConfigTime'] -and $manifest.APC.ExpectedConfigTime) {
    "Allow approximately $($manifest.APC.ExpectedConfigTime) for completion."
} else { 'Allow approximately [X] for completion.' }
$Script:SupportEmail = if ($manifest.APC.PSObject.Properties['SupportEmail']) { [string]$manifest.APC.SupportEmail } else { '' }
$controls['TxtSupport'].Text = if ($Script:SupportEmail) { "Still failing? E-mail the APC team: $Script:SupportEmail" } else { '' }

# Where the Installation Manager put the Medtronic apps (C: or D:): the pages show the paths on that drive and read
# this VM's DOC files from there. The run checks it again at the start (a problem stops the run there).
$Script:Install = $null
try { $Script:Install = Find-MedtronicInstall -Manifest $manifest } catch { }
$Script:Drive = if ($Script:Install -and -not $Script:Install.Error) { [string]$Script:Install.Drive } else { '' }
$Script:ViewManifest = if ($Script:Drive) { Set-ManifestMedtronicDrive -Manifest $manifest -Drive $Script:Drive } else { $manifest }
function ConvertTo-DrivePath([string]$Path) { if ($Script:Drive) { Convert-MedtronicPath -Path $Path -Drive $Script:Drive } else { $Path } }
$Script:DataRoot = ConvertTo-DrivePath ([string]$manifest.DataApps.LocalDataRoot)   # File Manager NewPath / Data Collector root

$controls['TxtUsername'].Text = "$env:USERDOMAIN\"
foreach ($site in $manifest.Sites) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $site
    $controls['CmbSiteCode'].Items.Add($item) | Out-Null
}

function Get-SelectedSite { if ($controls['CmbSiteCode'].SelectedItem) { [string]$controls['CmbSiteCode'].SelectedItem.Content } else { '' } }
function Get-SvcAccountName { "$($manifest.ServiceAccounts.ServiceAccountPrefix)$(Get-SelectedSite)" }   # SVC-APC-MPR

# Site DB connection from manifest SiteServers: shown as one read-only line; the fields only when something is missing
function Update-SiteDBFields {
    $site  = Get-SelectedSite
    $entry = if ($site -and $manifest.SiteServers -and $manifest.SiteServers.PSObject.Properties[$site]) { $manifest.SiteServers.$site } else { $null }
    $controls['TxtSiteDBHost'].Text = if ($entry -and $entry.Host) { [string]$entry.Host } else { '' }
    $controls['TxtSiteDBUser'].Text = if ($entry -and $entry.User) { [string]$entry.User } else { '' }
    $controls['PwdSiteDB'].Password = ''
    if ($entry -and $entry.PasswordB64) {
        try { $controls['PwdSiteDB'].Password = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.PasswordB64)) } catch { }
    }
    $complete = $controls['TxtSiteDBHost'].Text -and $controls['TxtSiteDBUser'].Text -and $controls['PwdSiteDB'].Password
    $controls['PanelSiteDBEdit'].Visibility = if ($complete) { 'Collapsed' } else { 'Visible' }
    $controls['RunSiteDBHost'].Text = if ($complete) { $controls['TxtSiteDBHost'].Text } else { '' }
    $controls['RunSiteDBNote'].Text = if ($complete) { "$Script:Dot set for $site" } else { "not set for $site in the manifest - enter it below" }
    $controls['TxtSvcAccountLabel'].Text = Get-SvcAccountName
    $controls['TxtSigninHint'].Text = "Sign in with your domain account and choose your site. Windows must be signed in as $($manifest.ServiceAccounts.Domain)\$(Get-SvcAccountName)."
}

# ---- Data applications -------------------------------------------------------------

function Get-FilesPerPart([string]$Type) {
    foreach ($n in 3, 2, 1) { $rb = $controls["RbFpp_${Type}_$n"]; if ($rb -and $rb.IsChecked) { return $n } }
    return 1
}

# Instrument names a 'files per part' gives (CMM1 / CONTRACER1..3), shown on hover
function Update-FilesPerPartTip([string]$Type) {
    $inst = $manifest.DataApps.Instruments | Where-Object { $_.Type -eq $Type } | Select-Object -First 1
    $n = Get-FilesPerPart $Type
    $controls["BdFpp_$Type"].ToolTip = if ($n -eq 1) { [string]$inst.SingleName } else { (1..$n | ForEach-Object { "$Type$_" }) -join ', ' }
}

# Prefill Data Applications instrument selection from manifest SiteDefaults (paths on the install drive)
function Update-DataAppsDefaults {
    $site = Get-SelectedSite
    $da   = $manifest.DataApps
    $defs = if ($site -and $da.SiteDefaults.PSObject.Properties[$site]) { $da.SiteDefaults.$site } else { $da.SiteDefaults.Default }
    foreach ($inst in $da.Instruments) {
        $t = $inst.Type
        $p = $defs.PSObject.Properties[$t]
        $d = if ($p) { $p.Value } else { $null }
        $count = if ($d -and $t -ne 'BENCH') { [math]::Min(3, [math]::Max(1, [int]$d.Count)) } else { 1 }
        $controls["RbFpp_${t}_$count"].IsChecked = $true
        foreach ($n in 1,2,3) { $controls["ChkInst_${t}_$n"].IsChecked = [bool]($d -and ($n -in @($d.CNCs))) }
        $controls["TxtInstSrc_$t"].Text = if ($d) { ConvertTo-DrivePath ([string]$d.SourcePath) }    else { '' }
        $controls["TxtInstErr_$t"].Text = if ($d) { ConvertTo-DrivePath ([string]$d.ErrorPath) }     else { '' }
        $controls["TxtInstBc_$t"].Text  = if ($d) { ConvertTo-DrivePath ([string]$d.BroadcastPath) } else { '' }
        Update-FilesPerPartTip $t
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
        @{
            Type          = $t
            Count         = $(if ($t -eq 'BENCH') { 1 } else { Get-FilesPerPart $t })
            CNCs          = $cncs
            SourcePath    = $controls["TxtInstSrc_$t"].Text.Trim()
            ErrorPath     = $controls["TxtInstErr_$t"].Text.Trim()
            BroadcastPath = $controls["TxtInstBc_$t"].Text.Trim()
        }
    }
}

foreach ($inst in $manifest.DataApps.Instruments) {
    # "More" shows an instrument's error and MES copy folders (the button's Tag is the instrument type)
    $controls["BtnInstMore_$($inst.Type)"].Add_Click({
        param($btn)
        $panel = $controls["PanelInstMore_$($btn.Tag)"]
        $open  = $panel.Visibility -ne 'Visible'
        $panel.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
        $btn.Content      = if ($open) { 'Less' } else { 'More' }
    })
    foreach ($n in 1,2,3) { $controls["RbFpp_$($inst.Type)_$n"].Add_Checked({ param($rb) Update-FilesPerPartTip ([string]$rb.Tag) }) }
}

# ---- Machines & DOC ---------------------------------------------------------------

$Script:CurrentDOC     = @{}      # what this VM has configured now: @{ 1 = 'Citizen 08'; ... } (read after sign-in)
$Script:CurrentDOCRead = $false
$Script:DOCTimeNow     = @{}      # DOC timeouts read from this VM's DOC files
$Script:DOCTimeBoxes   = [ordered]@{ Insp = 'MaxTimeToWaitForAllInspectionGroups'; Calc = 'MaxTimeToWaitForAllCalculationGroups'; Oper = 'MaxTimeToWaitForOperatorResponse' }
$Script:TagStyles = @{
    cur = @{ Text = 'Current'; Bg = '#EEF2FF'; Fg = '#3451D1'; Tip = 'Configured on this VM now' }
    neu = @{ Text = 'New';     Bg = '#F0FDF4'; Fg = '#166534'; Tip = 'Not configured on this VM yet' }
    chg = @{ Text = 'Changed'; Bg = '#FFFBEB'; Fg = '#B45309'; Tip = 'Your edit; listed on Review' }
}

function Set-Tag {
    param([System.Windows.Controls.Border]$Border, [System.Windows.Controls.TextBlock]$Text, [string]$Kind)
    if (-not $Kind) { $Border.Visibility = 'Collapsed'; return }
    $t = $Script:TagStyles[$Kind]
    $Border.Visibility = 'Visible'; $Border.Background = $t.Bg; $Border.ToolTip = $t.Tip
    $Text.Text = $t.Text; $Text.Foreground = $t.Fg
}

function Get-DOCCount {
    foreach ($n in 3, 2, 1) { if ($controls["RbDoc$n"].IsChecked) { return $n } }
    return 3
}

function Get-CHMIMachineName([int]$N) {
    $cmb = $controls["CmbDOCMachine$N"]
    if ($cmb.SelectedItem) { [string]$cmb.SelectedItem.Content } else { '' }
}

# Markers are shown for Component Configuration / Update: it starts from what this VM has
function Test-ShowVmTags { (Get-ConfigType) -eq 'component' -and $Script:CurrentDOCRead }

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

# Family, Device Nr and DLL for each assigned machine, as Step 7 will derive them
function Update-DOCDetails {
    foreach ($n in 1,2,3) {
        $name = Get-CHMIMachineName $n
        $m    = @($Global:FetchedMachines) | Where-Object { $_.MachineName -eq $name } | Select-Object -First 1
        $fam = ''; $dev = ''; $dll = ''; $tip = $null; $devColor = '#1C2136'
        if ($m) {
            $info = Get-CNCDeviceInfo -Machine $m -Manifest $manifest
            $fam  = $info.Family; $dll = $info.DriverDll
            if ($info.Error) { $dev = 'Error'; $tip = $info.Error; $devColor = '#EF4444' } else { $dev = $info.DeviceNr }
            if (-not $info.Error -and $info.PdmName -ne $m.MachineName) { $tip = "CNCnetPDM / deviceWise name: '$($info.PdmName)' (CNCnetPDM keeps 15 characters)" }
        }
        $controls["TxtDOCFam$n"].Text       = $fam
        $controls["TxtDOCDev$n"].Text       = $dev
        $controls["TxtDOCDev$n"].ToolTip    = $tip
        $controls["TxtDOCDev$n"].Foreground = $devColor
        $controls["TxtDOCDll$n"].Text       = $dll
    }
}

# Current / New / Changed against what this VM has now; CNCs dropped by a lower DOC count are listed
function Update-DOCTags {
    $on  = Test-ShowVmTags
    $cnt = Get-DOCCount
    $cur = $Script:CurrentDOC
    $controls['PanelMachTags'].Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    $w = if ($on) { '86' } else { '0' }   # GridLength from text, as the other column widths
    $controls['ColDOCTagHead'].Width = $w
    foreach ($n in 1,2,3) {
        $controls["ColDOCTag$n"].Width = $w
        $kind = if (-not $on) { '' } elseif (-not $cur.ContainsKey($n)) { 'neu' } elseif ((Get-CHMIMachineName $n) -ne $cur[$n]) { 'chg' } else { 'cur' }
        Set-Tag $controls["BdDOCTag$n"] $controls["TxtDOCTag$n"] $kind
    }
    $controls['TxtDocNow'].Text = if ($on) { "On this VM now: $($cur.Count)" } else { '' }
    Set-Tag $controls['BdDocCountTag'] $controls['TxtDocCountTag'] $(if (-not $on) { '' } elseif ($cnt -ne $cur.Count) { 'chg' } else { 'cur' })

    $panel = $controls['PanelDroppedRows']
    $panel.Children.Clear()
    if ($on) {
        foreach ($n in @($cur.Keys | Where-Object { $_ -gt $cnt } | Sort-Object)) {
            $g = New-Object System.Windows.Controls.Grid
            $g.Margin = '0,0,0,10'
            foreach ($wd in '60', '1.5*', '*', '86') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $wd; [void]$g.ColumnDefinitions.Add($c) }
            $a = New-TextBlock -Text "CNC$n" -Color '#94A3B8' -Weight 'SemiBold'
            $b = New-TextBlock -Text $cur[$n] -Color '#94A3B8'; $b.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
            $c3 = New-TextBlock -Text "Configured now; removed with $cnt DOC instance$(if ($cnt -gt 1) { 's' })" -Color '#B45309' -Size 12; $c3.Margin = '12,0,0,0'
            $bd = New-Object System.Windows.Controls.Border; $bd.Style = $window.FindResource('TagChip'); $bd.Margin = '8,0,0,0'
            $tx = New-Object System.Windows.Controls.TextBlock; $tx.FontSize = 11; $tx.FontWeight = 'SemiBold'; $bd.Child = $tx
            Set-Tag $bd $tx 'chg'
            [System.Windows.Controls.Grid]::SetColumn($b, 1); [System.Windows.Controls.Grid]::SetColumn($c3, 2); [System.Windows.Controls.Grid]::SetColumn($bd, 3)
            foreach ($el in $a, $b, $c3, $bd) { [void]$g.Children.Add($el) }
            [void]$panel.Children.Add($g)
        }
    }
    $controls['BtnUndoMach'].IsEnabled = $on -and @(Get-MachineChanges).Count -gt 0
}

function Update-DOCRows {
    $cnt = Get-DOCCount
    $controls['GridDOCRow2'].Visibility = if ($cnt -ge 2) { 'Visible' } else { 'Collapsed' }
    $controls['GridDOCRow3'].Visibility = if ($cnt -ge 3) { 'Visible' } else { 'Collapsed' }
    Update-DOCMachineChoices
    Update-DOCDetails
    Update-DOCTags
    Update-DataAppsCNCVisibility -CncCount $cnt
}

# Puts this VM's DOC assignment into the page (Component / Update and Verification start from it)
function Set-DOCFromVm {
    $cur = $Script:CurrentDOC
    if ($cur.Count -gt 0) { $controls["RbDoc$($cur.Count)"].IsChecked = $true }
    foreach ($n in @($cur.Keys)) {
        $cmb = $controls["CmbDOCMachine$n"]
        $idx = [array]::IndexOf(@($cmb.Items | ForEach-Object { [string]$_.Content }), [string]$cur[$n])
        if ($idx -ge 0) { $cmb.SelectedIndex = $idx }
    }
    Update-DOCRows
}

foreach ($n in 1,2,3) {
    $controls["RbDoc$n"].Add_Checked({ Update-DOCRows })
    $controls["CmbDOCMachine$n"].Add_SelectionChanged({ Update-DOCMachineChoices; Update-DOCDetails; Update-DOCTags })
}
$controls['BtnUndoMach'].Add_Click({
    Set-DOCFromVm
    foreach ($k in $Script:DOCTimeBoxes.Keys) { $controls["TxtDOCTime$k"].Text = [string]$Script:DOCTimeNow[$Script:DOCTimeBoxes[$k]] }
})

# DOC timeouts (Advanced): one value for every DOC instance; only a changed value goes to Step 9
function Update-DOCTimeNotes {
    foreach ($k in $Script:DOCTimeBoxes.Keys) {
        $now = [string]$Script:DOCTimeNow[$Script:DOCTimeBoxes[$k]]
        $box = $controls["TxtDOCTime$k"]; $note = $controls["TxtDOCTimeNote$k"]
        if (-not $now) { $note.Text = 'Not found on this VM'; $note.Foreground = '#94A3B8'; $box.IsEnabled = $false; continue }
        $box.IsEnabled = $true
        $v = $box.Text.Trim()
        if ($v -notmatch '^\d+$' -or [int64]$v -lt 1) { $note.Text = 'Whole seconds'; $note.Foreground = '#EF4444' }
        elseif ([int64]$v -ne [int64]$now) { $note.Text = 'Changed'; $note.Foreground = '#B45309' }
        else { $note.Text = ''; $note.Foreground = '#64748B' }
    }
}
function Read-DOCTimeouts {
    $Script:DOCTimeNow = Get-DOCTimeouts -Manifest $Script:ViewManifest
    foreach ($k in $Script:DOCTimeBoxes.Keys) { $controls["TxtDOCTime$k"].Text = [string]$Script:DOCTimeNow[$Script:DOCTimeBoxes[$k]] }
    Update-DOCTimeNotes
}
function Get-DOCTimeoutChanges {
    # @{ <setting> = <seconds> } for the values changed on the page
    $res = @{}
    foreach ($k in $Script:DOCTimeBoxes.Keys) {
        $key = $Script:DOCTimeBoxes[$k]; $now = [string]$Script:DOCTimeNow[$key]; $v = $controls["TxtDOCTime$k"].Text.Trim()
        if ($now -and $v -match '^\d+$' -and [int64]$v -ne [int64]$now) { $res[$key] = [string][int64]$v }
    }
    $res
}
foreach ($k in $Script:DOCTimeBoxes.Keys) { $controls["TxtDOCTime$k"].Add_TextChanged({ Update-DOCTimeNotes }) }

# Changes against this VM for Review: @(@{ K; From; To })
function Get-MachineChanges {
    $list = @()
    if (-not (Test-ShowVmTags)) { return $list }
    $cur = $Script:CurrentDOC; $cnt = Get-DOCCount
    if ($cnt -ne $cur.Count) { $list += @{ K = 'DOC instances'; From = [string]$cur.Count; To = [string]$cnt } }
    foreach ($n in 1,2,3) {
        $was = if ($cur.ContainsKey($n)) { [string]$cur[$n] } else { '' }
        $now = if ($n -le $cnt) { Get-CHMIMachineName $n } else { '' }
        if ($was -ne $now) { $list += @{ K = "CNC$n machine"; From = $(if ($was) { $was } else { 'not configured' }); To = $(if ($now) { $now } else { 'not configured' }) } }
    }
    $list
}

# ---- CNCnetPDM license ------------------------------------------------------------

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

# Step 11 setting values for the chosen site (manifest ABB800xA.Settings; data folders on the install drive)
function Get-CHMISiteSettings {
    Get-800xASettings -Manifest $manifest -State @{ SiteCode = (Get-SelectedSite); DataAppsLocalRoot = $Script:DataRoot }
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
    $controls['TxtShiftHint'].Text = if ($both) { 'Whole hours only. Applies to the cells set to Both.' } else { 'Only needed when a cell is set to Both.' }
}

function Update-CHMIPage {
    Read-CHMICurrentValues
    $cnt = Get-DOCCount
    foreach ($n in 1..3) {
        $controls["GridCHMIRow$n"].Visibility = if ($n -le $cnt) { 'Visible' } else { 'Collapsed' }
        $controls["TxtCHMIMachine$n"].Text    = Get-CHMIMachineName $n
        $controls["TxtCHMICurrent$n"].Text    = Get-CHMITriggerText $Script:CHMICurrent[$n]
        $controls["TxtCHMICurrent$n"].ToolTip = if ($Script:CHMICurrent[$n]) { $null } else { 'Could not be read from 800xA. Pick Button or Both.' }
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

# ---- Backup to restore (Configuration Restore) -----------------------------------------

$Script:RestoreInfo  = $null
$Script:RestoreComps = [ordered]@{ dw = 'deviceWise'; doc = 'DOC and data applications'; cnc = 'CNCnetPDM' }

# Reads the chosen folder (Get-ApcBackupInfo): where the backup comes from, what it has; another VM's backup or
# another release cannot be restored (D01555607 4.2: the backup must correspond to this VM and APC version)
function Update-RestorePage {
    $path = $controls['TxtRestoreFolder'].Text.Trim()
    $Script:RestoreInfo = $null
    $controls['PanelRestoreInfo'].Visibility = 'Collapsed'
    $controls['PanelRestoreProblem'].Visibility = 'Collapsed'
    if (-not $path) { return }
    $info = Get-ApcBackupInfo -Path $path
    $problem = $info.Problem
    if (-not $problem -and -not $info.VM) { $problem = 'The backup does not say which VM it is from (no config_state.json or deviceWise\RESTORE.txt in the run folder).' }
    if (-not $problem -and $info.VM -ine $env:COMPUTERNAME) { $problem = "This backup is from $($info.VM). Only this VM's own backups ($env:COMPUTERNAME) can be restored." }
    if (-not $problem -and $info.Release -and $Script:Release.ReleaseLabel -and $info.Release -ne $Script:Release.ReleaseLabel) {
        $problem = "This backup is from $($info.Release); this VM is on $($Script:Release.ReleaseLabel). Only a backup of the same APC release can be restored."
    }
    if ($problem) {
        $controls['TxtRestoreProblem'].Text = $problem
        $controls['PanelRestoreProblem'].Visibility = 'Visible'
        return
    }
    $Script:RestoreInfo = $info
    $rows = $controls['PanelRestoreRows']; $rows.Children.Clear()
    Add-SummaryRow $rows 'Backup' $info.Backups
    Add-SummaryRow $rows 'From' ((@($info.VM, $info.When, $info.Type) | Where-Object { $_ }) -join "  $Script:Dot  ")
    if ($info.Release) { Add-SummaryRow $rows 'Release' $info.Release }
    if ($info.State -and $info.State.PSObject.Properties['DOCMachineAssignments']) {
        $i = 0; Add-SummaryRow $rows 'DOC instances' ((@($info.State.DOCMachineAssignments) | ForEach-Object { $i++; "CNC$i $_" }) -join "  $Script:Dot  ")
    }
    foreach ($k in $Script:RestoreComps.Keys) {
        $cb = $controls["ChkRestore_$k"]
        $cb.IsEnabled = [bool]$info.Components[$k]
        $cb.IsChecked = [bool]$info.Components[$k]
        $cb.ToolTip   = if ($info.Components[$k]) { $null } else { 'Not in this backup' }
    }
    $controls['PanelRestoreInfo'].Visibility = 'Visible'
}
function Get-RestorePicks { @($Script:RestoreComps.Keys | Where-Object { $controls["ChkRestore_$_"].IsEnabled -and $controls["ChkRestore_$_"].IsChecked -eq $true }) }
function Test-RestorePage {
    Update-RestorePage
    if (-not $Script:RestoreInfo) { Show-Warning $(if ($controls['TxtRestoreProblem'].Text -and $controls['PanelRestoreProblem'].Visibility -eq 'Visible') { $controls['TxtRestoreProblem'].Text } else { 'Choose the backup folder to restore.' }); return $false }
    if (-not @(Get-RestorePicks).Count) { Show-Warning 'Tick at least one component to restore.'; return $false }
    return $true
}
$controls['BtnRestoreBrowse'].Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the run folder (or its Backups folder) of the backup to restore'
    $start = $controls['TxtRestoreFolder'].Text.Trim()
    $dlg.SelectedPath = if ($start -and (Test-Path -LiteralPath $start)) { $start } else { $Script:ApcRoot }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $controls['TxtRestoreFolder'].Text = $dlg.SelectedPath; Update-RestorePage }
})
$controls['TxtRestoreFolder'].Add_LostFocus({ Update-RestorePage })

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

function Test-PostgresPassword {
    # $true when the local PostgreSQL accepts the postgres password (or psql is not here: Step 2 still checks)
    $psql = Join-Path ([string]$manifest.PostgreSQL.BinDir) 'psql.exe'
    if (-not (Test-Path -LiteralPath $psql)) { return $true }
    # a separate process and its exit code only: with ErrorActionPreference Stop, psql's error text would throw
    $err = Join-Path $env:TEMP 'apc_pg_check.txt'
    $window.Cursor = 'Wait'
    try {
        $env:PGPASSWORD = $controls['PwdPostgres'].Password
        $p = Start-Process -FilePath $psql -ArgumentList "-U postgres -h localhost -p $($manifest.PostgreSQL.DefaultPort) -w -t -c `"select 1`"" `
                 -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$err.out" -RedirectStandardError $err
        return ($p.ExitCode -eq 0)
    } catch {
        return $true
    } finally {
        $env:PGPASSWORD = $null
        Remove-Item $err, "$err.out" -Force -ErrorAction SilentlyContinue
        $window.Cursor = $null
    }
}

function Show-Warning {
    param([string]$Message, [string]$Title = 'Missing')
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Warning') | Out-Null
}

function New-TextBlock {
    param([string]$Text, [string]$Color = '#1C2136', [string]$Weight = 'Normal', [double]$Size = 13)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.Foreground = $Color; $tb.FontWeight = $Weight; $tb.FontSize = $Size
    $tb.TextWrapping = 'Wrap'; $tb.VerticalAlignment = 'Center'
    return $tb
}

function Set-StepState {
    param([int]$Index, [string]$State)
    $icon   = $controls["TxtStep${Index}Icon"]
    $status = $controls["TxtStep${Index}Status"]
    $rerun  = $controls["BtnRerun${Index}"]
    if (-not $icon) { return }
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
    return @{
        CurrentPhase     = 1
        OperatorName     = $controls['TxtUsername'].Text.Trim()
        OperatorRole     = 'Service Account'
        SiteCode         = (Get-SelectedSite)
        SiteDBHost       = $controls['TxtSiteDBHost'].Text.Trim()
        SiteDBUser       = $controls['TxtSiteDBUser'].Text.Trim()
        SINCEmail        = $controls['TxtSINCEmail'].Text.Trim()
        DOCCount         = Get-DOCCount
        VMHostname       = $env:COMPUTERNAME
        StartTime        = (Get-Date -Format 'o')
        CompletedPhases  = @()
        CNCMachines      = @()
        AppVersion       = $Script:AppVersion
        ReleaseLabel     = [string]$Script:Release.ReleaseLabel
    }
}

function Save-State {
    param([hashtable]$State)
    $dir = Split-Path $Script:StateFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    $safe = @{}
    foreach ($k in $State.Keys) {
        # passwords never, and the verification results stay in memory (the report and the draft have them)
        if ($State[$k] -isnot [System.Security.SecureString] -and $k -notin 'VerificationChecks', 'VerificationFills', 'VerificationComments') { $safe[$k] = $State[$k] }
    }
    $json = $safe | ConvertTo-Json -Depth 10
    $json | Set-Content $Script:StateFile -Encoding UTF8
    if ($State['RunRoot']) { $json | Set-Content (Join-Path $State['RunRoot'] 'config_state.json') -Encoding UTF8 }
}

# The window's run log (what "Show log" shows) -> <RunRoot>\Logs\Wizard.log: each line is appended as it is shown
# (Add-RunLogText), so the file is complete up to the last line even if the window stops; Save-RunLog rewrites it
# from the window after each step.
function Add-RunLogText {
    param([System.Windows.Controls.TextBox]$Box, [string]$Text)
    $Box.AppendText($Text)
    if (-not $Script:AutoState -or -not $Script:AutoState['RunRoot']) { return }
    $file = switch ($Box.Name) { 'LogAll' { 'Wizard.log' } 'LogVerification' { 'Verification.log' } 'LogReport' { 'DraftChecklist.log' } default { '' } }
    if (-not $file) { return }
    try {
        $dir = Join-Path $Script:AutoState['RunRoot'] 'Logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText((Join-Path $dir $file), $Text)
    } catch { }
}

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
    Add-RunLogText $controls['LogAll'] "`r`n$bar`r`n$pad  $Title`r`n$bar`r`n"
    $controls['LogAll'].ScrollToEnd()
}

# ---- Wizard pages -------------------------------------------------------------

$Script:PageIndex     = 0
$Script:RunState      = 'none'    # none | running | failed | done (Configure page)
$Script:Busy          = $false    # verification or draft running on the last page
$Script:Drafted       = $false
$Script:VerifyStarted = $false

function Get-ConfigType {
    foreach ($id in $Script:ConfigTypes.Keys) { if ($controls["RbType_$id"].IsChecked) { return $id } }
    return 'initial'
}

function Get-PickedComponents {
    @($Script:Components.Keys | Where-Object { $controls["ChkComp_$_"].IsChecked -eq $true })
}

# Steps the Configure page runs (Step 13 runs on the last page)
function Get-PlanSteps {
    switch (Get-ConfigType) {
        'initial' { return @(1..12) }
        'restore' { return @(1, 14, 12) }   # Restore runs before the backup of the restored state
        'verify'  { return @() }
        default {
            $steps = @(1, 12)
            foreach ($c in Get-PickedComponents) { $steps += $Script:Components[$c].Steps }
            return @($steps | Sort-Object -Unique)
        }
    }
}

function Get-WizardPages {
    switch (Get-ConfigType) {
        'initial' { return @('type', 'signin', 'machines', 'components', 'dataapps', 'chmi', 'review', 'run', 'verify') }
        'verify'  { return @('type', 'signin', 'verify') }
        'restore' { return @('type', 'signin', 'restore', 'review', 'run', 'verify') }
        default {
            $picked = @(Get-PickedComponents)
            $pages  = @('type', 'signin', 'scope')
            if (@($picked | Where-Object { $_ -in 'sinc', 'dw', 'cnc', 'doc', 'da', 'chmi' }).Count) { $pages += 'machines' }
            if ('dw' -in $picked -or 'cnc' -in $picked) { $pages += 'components' }
            if ('da' -in $picked) { $pages += 'dataapps' }
            if ('chmi' -in $picked) { $pages += 'chmi' }
            return $pages + @('review', 'run', 'verify')
        }
    }
}

function Update-NavList {
    param([string[]]$Pages)
    $nav = $controls['NavList']
    $nav.Children.Clear()
    $runAt  = [array]::IndexOf($Pages, 'run')
    $locked = $Script:RunState -ne 'none'   # once started, the pages before Configure are closed
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
        $canGo = $done -and $Script:RunState -ne 'running' -and -not $Script:Busy -and -not ($locked -and $runAt -ge 0 -and $i -lt $runAt)
        $btn.Cursor     = if ($canGo) { 'Hand' } else { 'Arrow' }
        if ($canGo) { $btn.Add_Click({ param($b) $Script:PageIndex = [int]$b.Tag; Update-Wizard }) }
        [void]$nav.Children.Add($btn)
    }
}

function Update-TypePage {
    $isVerify = (Get-ConfigType) -eq 'verify'
    $controls['PanelBeforeStart'].Visibility = if ($isVerify) { 'Collapsed' } else { 'Visible' }
    $controls['RunWarnTitle'].Text = if ($isVerify) { 'No changes are made.' } else { 'Change control required.' }
    $controls['RunWarnText'].Text  = if ($isVerify) {
        'The checklist is created as a draft for review and reference.'
    } else {
        'Configuration changes go through change control per APC System Change Management (D01458108). The Installation Verification Checklist (D01555616) must be approved before configuration starts, and the Configuration Verification Checklist (D01555624) must be completed and approved.'
    }
}

function Add-SummaryRow {
    param([System.Windows.Controls.Panel]$Panel, [string]$Key, [string]$Value)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,0,0,6'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '180'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    $v = New-TextBlock -Text $Value -Weight 'SemiBold'
    [System.Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$g.Children.Add((New-TextBlock -Text $Key -Color '#475569'))
    [void]$g.Children.Add($v)
    [void]$Panel.Children.Add($g)
}

function Update-ReviewPage {
    $type  = Get-ConfigType
    $pages = Get-WizardPages
    $panel = $controls['PanelSummary']
    $panel.Children.Clear()
    Add-SummaryRow $panel 'Configuration type' $Script:ConfigTypes[$type].Name
    Add-SummaryRow $panel 'Site' (Get-SelectedSite)
    Add-SummaryRow $panel 'VM' $env:COMPUTERNAME
    Add-SummaryRow $panel 'Release' ([string]$Script:Release.ReleaseLabel)
    if ($type -eq 'restore' -and $Script:RestoreInfo) {
        Add-SummaryRow $panel 'Backup' $Script:RestoreInfo.Backups
        Add-SummaryRow $panel 'Backup from' ((@($Script:RestoreInfo.VM, $Script:RestoreInfo.When, $Script:RestoreInfo.Type) | Where-Object { $_ }) -join "  $Script:Dot  ")
        Add-SummaryRow $panel 'Restore' ((Get-RestorePicks | ForEach-Object { $Script:RestoreComps[$_] }) -join ', ')
    }
    if ($type -eq 'component') {
        $picked = Get-PickedComponents | ForEach-Object { ($Script:Components[$_].Label -split ' \(')[0] }
        Add-SummaryRow $panel 'Components' $(if ($picked) { $picked -join ', ' } else { 'None selected' })
    }
    $cnt = Get-DOCCount
    if ('machines' -in $pages) {
        Add-SummaryRow $panel 'DOC instances' ((1..$cnt | ForEach-Object { "CNC$_ $(Get-CHMIMachineName $_)" }) -join "  $Script:Dot  ")
    }
    if ('chmi' -in $pages) {
        Add-SummaryRow $panel 'Verification trigger' ((1..$cnt | ForEach-Object {
            $sel = $controls["CmbCHMITrigger$_"].SelectedItem
            $val = if ($sel) { [string]$sel.Tag } else { '' }
            "CNC$_ $(Get-CHMITriggerText $val)$(if ($val -and $Script:CHMICurrent[$_] -and $val -ne $Script:CHMICurrent[$_]) { ' (changed)' })"
        }) -join "  $Script:Dot  ")
    }
    Add-SummaryRow $panel 'Run folder' "$Script:ApcRoot\$($Script:ConfigTypes[$type].Folder)_[yyyyMMdd-HHmmss]"

    # What changes on this VM (Component / Update starts from what is there now)
    $changes = @()
    if ('machines' -in $pages) {
        $changes += @(Get-MachineChanges)
        $tmo = Get-DOCTimeoutChanges
        foreach ($k in $Script:DOCTimeBoxes.Keys) {
            $key = $Script:DOCTimeBoxes[$k]
            if ($tmo.ContainsKey($key)) {
                $label = ($Script:DOCTimeoutDefs | Where-Object { $_.Key -eq $key }).Label
                $changes += @{ K = "DOC: $label"; From = "$($Script:DOCTimeNow[$key]) s"; To = "$($tmo[$key]) s" }
            }
        }
    }
    $controls['PanelChanges'].Visibility = if ($type -eq 'component') { 'Visible' } else { 'Collapsed' }
    $rowsPanel = $controls['PanelChangeRows']
    $rowsPanel.Children.Clear()
    if (-not $changes) {
        [void]$rowsPanel.Children.Add((New-TextBlock -Text 'No values changed. The selected components are re-applied with the values configured now.' -Color '#334155'))
    }
    foreach ($c in $changes) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = '0,0,0,6'
        foreach ($wd in '200', '*', '20', '*') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; [void]$g.ColumnDefinitions.Add($cd) }
        $a = New-TextBlock -Text $c.K -Color '#475569'
        $b = New-TextBlock -Text $c.From -Color '#64748B' -Size 12; $b.FontFamily = 'Consolas'
        $ar = New-TextBlock -Text ([string][char]0x2192) -Color '#94A3B8'; $ar.HorizontalAlignment = 'Center'
        $d = New-TextBlock -Text $c.To -Color '#B45309' -Weight 'SemiBold' -Size 12; $d.FontFamily = 'Consolas'
        [System.Windows.Controls.Grid]::SetColumn($b, 1); [System.Windows.Controls.Grid]::SetColumn($ar, 2); [System.Windows.Controls.Grid]::SetColumn($d, 3)
        foreach ($el in $a, $b, $ar, $d) { [void]$g.Children.Add($el) }
        [void]$rowsPanel.Children.Add($g)
    }

    $steps = Get-PlanSteps
    $restarts = @()
    if ($type -eq 'restore') {
        $picks = @(Get-RestorePicks)
        if ('dw' -in $picks)  { $restarts += 'deviceWise (dwcore, dwts)' }
        if ('cnc' -in $picks) { $restarts += 'CNCnetPDM' }
        if ('doc' -in $picks) { $restarts += 'the DOC instances and the data applications' }
    }
    if (@($steps | Where-Object { $_ -in 4, 5, 6, 8 }).Count) { $restarts += 'deviceWise (dwcore)' }
    if (7 -in $steps)  { $restarts += 'CNCnetPDM' }
    if (9 -in $steps)  { $restarts += 'the DOC instances' }
    if (10 -in $steps) { $restarts += 'the data applications' }
    $lines = @()
    if ($restarts) { $lines += "1. $($restarts -join ', ') restart$(if ($restarts.Count -eq 1) { 's' }) during the run. Data collection on this VM pauses briefly." }
    $lines += "$($lines.Count + 1). Nothing to do on the VM. Every changed file is backed up into this run's Backups folder."
    $controls['TxtWhileRuns'].Text = $lines -join "`n"
}

function Update-VerifyPage {
    $isVerify = (Get-ConfigType) -eq 'verify'
    $controls['TxtReportHint'].Text = if ($isVerify) {
        'Review the results. A draft Configuration Verification Checklist (D01555624) is optional.'
    } else { 'Review the results, then create the draft Configuration Verification Checklist (D01555624). It does not approve it: review and QA sign it independently.' }
    $controls['PanelReason'].Visibility = if ($isVerify) { 'Visible' } else { 'Collapsed' }
    $controls['TxtReason'].Visibility   = if ($isVerify) { 'Collapsed' } else { 'Visible' }
    $controls['TxtReason'].Text         = $Script:ConfigTypes[(Get-ConfigType)].Name
    $controls['BtnGenerateReport'].Content   = if ($Script:Drafted) { 'Create draft again' } else { 'Create draft checklist' }
    $controls['BtnGenerateReport'].IsEnabled = -not $Script:Busy -and $Script:AutoState -and $Script:AutoState['VerificationChecks']
    $controls['BtnRunVerification'].IsEnabled = -not $Script:Busy

    # Verification: the DOC instances read from this VM
    $controls['PanelVmRead'].Visibility = if ($isVerify) { 'Visible' } else { 'Collapsed' }
    if ($isVerify) {
        $grid = $controls['GridVmRows']
        $grid.Children.Clear(); $grid.RowDefinitions.Clear()
        $rows = @(@('DOC', 'MACHINE', 'DEVICE NR', 'CELL'))
        foreach ($n in @($Script:CurrentDOC.Keys | Sort-Object)) {
            $m = @($Global:FetchedMachines) | Where-Object { $_.MachineName -eq $Script:CurrentDOC[$n] } | Select-Object -First 1
            $dev = if ($m) { (Get-CNCDeviceInfo -Machine $m -Manifest $manifest).DeviceNr } else { '' }
            $rows += ,@("DOC-$n", [string]$Script:CurrentDOC[$n], [string]$dev, "Cell_$n")
        }
        if ($rows.Count -eq 1) { $rows += ,@('', 'No configured DOC instance found on this VM', '', '') }
        for ($r = 0; $r -lt $rows.Count; $r++) {
            $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = 'Auto'; [void]$grid.RowDefinitions.Add($rd)
            for ($c = 0; $c -lt 4; $c++) {
                $tb = if ($r -eq 0) { $h = New-TextBlock -Text $rows[$r][$c] -Color '#64748B' -Weight 'SemiBold' -Size 11; $h }
                      else { New-TextBlock -Text $rows[$r][$c] -Weight $(if ($c -eq 0) { 'SemiBold' } else { 'Normal' }) }
                if ($r -gt 0 -and $c -ge 2) { $tb.FontFamily = 'Consolas' }
                $tb.Margin = '0,0,0,6'
                [System.Windows.Controls.Grid]::SetRow($tb, $r); [System.Windows.Controls.Grid]::SetColumn($tb, $c)
                [void]$grid.Children.Add($tb)
            }
        }
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
    switch ($key) {
        'type'     { Update-TypePage }
        'machines' { Update-DOCTags }
        'chmi'     { Update-CHMIPage }
        'review'   { Update-ReviewPage }
        'verify'   { Update-VerifyPage }
    }

    $running = $Script:RunState -eq 'running' -or $Script:Busy
    $runAt   = [array]::IndexOf($pages, 'run')
    $started = $Script:RunState -ne 'none'
    $controls['BtnBack'].IsEnabled = $Script:PageIndex -gt 0 -and $key -ne 'run' -and -not $running -and
                                     -not ($started -and $runAt -ge 0 -and $Script:PageIndex - 1 -lt $runAt)
    $next = switch ($key) {
        'scope'  { @(Get-PickedComponents).Count -gt 0 }
        'run'    { $Script:RunState -eq 'done' }
        'verify' { $Script:Drafted -or (Get-ConfigType) -eq 'verify' }
        default  { $true }
    }
    $controls['BtnNext'].IsEnabled = $next -and -not $running
    $controls['BtnNext'].Content   = switch ($key) {
        'review' { 'Start configuration' }
        'run'    { 'Continue' }
        'verify' { 'Finish' }
        default  { 'Next' }
    }
    $controls['MainScroller'].ScrollToTop()
}

foreach ($id in $Script:ConfigTypes.Keys) { $controls["RbType_$id"].Add_Checked({ Update-Wizard }) }
foreach ($c in $Script:Components.Keys) {
    $controls["ChkComp_$c"].Add_Checked({ Update-Wizard })
    $controls["ChkComp_$c"].Add_Unchecked({ Update-Wizard })
}

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
            Add-RunLogText $capturedLog "$line`r`n"; $capturedLog.ScrollToEnd()
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

# ---- Run chain (Configure page) ---------------------------------------------

$Script:AutoIndex      = 0
$Script:AutoState      = $null
$Script:StepStartTime  = $null
$Script:RunTotal       = 0
$Script:RunDone        = 0
$Script:FailedIndex    = -1      # StepDefs index of the step that stopped the run
$Script:RunStepsAll    = @()     # the run's steps (a re-run sets AutoState.RunSteps to its own step)
$Global:FetchedMachines = @()

function Format-Elapsed([TimeSpan]$Elapsed) {
    if ($Elapsed.TotalSeconds -lt 60) { "$([math]::Round($Elapsed.TotalSeconds)) sec" } else { "$([math]::Floor($Elapsed.TotalMinutes)) min $($Elapsed.Seconds) sec" }
}

function Update-RunProgress {
    $controls['BarOverall'].Maximum    = [math]::Max(1, $Script:RunTotal)
    $controls['BarOverall'].Value      = $Script:RunDone
    $controls['TxtProgressLabel'].Text = "$($Script:RunDone) / $($Script:RunTotal) steps"
}

function Complete-Run {
    $Script:RunState = 'done'
    $controls['TxtRunTitle'].Text = 'Done'
    $controls['PanelRunDone'].Visibility = 'Visible'
    Add-RunLogText $controls['LogAll'] "`r`n-- Configuration complete $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --`r`n"
    Save-RunLog
    Save-State -State $Script:AutoState
    Update-Wizard
}

# A failed step stops the run (as in the Installation Manager): red card with Re-run and the support e-mail
function Stop-RunAtFailure {
    param([int]$Index)
    $mod = $Script:StepDefs | Where-Object { $_.Index -eq $Index }
    $Script:RunState = 'failed'
    $controls['TxtFailTitle'].Text = "$(if ($Index -eq 14) { 'Restore' } else { "Step $Index" }) $Script:Dot $($mod.Name) failed. The configuration stopped."
    $controls['PanelFail'].Visibility = 'Visible'
    $controls['TxtRunTitle'].Text = 'Stopped'
    $controls['ExpRunLog'].IsExpanded = $true
    Save-RunLog
    Update-Wizard
}

function Run-NextAutoModule {
    if ($Script:AutoIndex -ge $Script:StepDefs.Count) { Complete-Run; return }
    $mod = $Script:StepDefs[$Script:AutoIndex]
    if ($mod.Index -notin $Script:RunStepsAll) { $Script:AutoIndex++; Run-NextAutoModule; return }

    $Script:RunState = 'running'
    $controls['TxtRunTitle'].Text = 'Configuring'
    Add-LogSection -Title "Step $($mod.Index) -- $($mod.Name)"
    Set-StepState -Index $mod.Index -State 'Running'
    $Script:AutoState['CurrentPhase'] = $mod.Index
    $Script:StepStartTime = Get-Date
    Update-Wizard

    Start-ModuleInWindow -ModuleFile $mod.File -FunctionName $mod.Fn -State $Script:AutoState -LogBox $controls['LogAll'] -OnDone {
        param([bool]$ok)
        $doneIndex = $Script:StepDefs[$Script:AutoIndex].Index
        Add-RunLogText $controls['LogAll'] "-- $(if ($ok) {'Completed'} else {'Failed'}) in $(Format-Elapsed ((Get-Date) - $Script:StepStartTime)) --`r`n"
        $controls['LogAll'].ScrollToEnd()
        Save-RunLog
        if (-not $ok) {
            Set-StepState -Index $doneIndex -State 'Failed'
            $Script:FailedIndex = $Script:AutoIndex
            Stop-RunAtFailure -Index $doneIndex
            return
        }
        # Step 11 (CHMI) uses Paused state when manual steps are required
        Set-StepState -Index $doneIndex -State $(if ($doneIndex -eq 11 -and $Script:RSSync.Paused) { 'Paused' } else { 'Done' })
        $Script:RunDone++
        Update-RunProgress
        $Script:AutoIndex++
        Run-NextAutoModule
    }
}

# Re-run the step that stopped the run; when it passes, the run continues with the remaining steps
function Start-StepRerun {
    if ($Script:RunState -ne 'failed' -or $Script:FailedIndex -lt 0) { return }
    $mod = $Script:StepDefs[$Script:FailedIndex]
    $controls['PanelFail'].Visibility = 'Collapsed'
    $Script:RunState = 'running'
    $controls['TxtRunTitle'].Text = 'Configuring'
    Set-StepState -Index $mod.Index -State 'Running'
    $Script:AutoState['RunSteps'] = @($mod.Index)   # a re-run is its own run (writes CNCAsset / CNCType itself)
    Add-LogSection -Title "Step $($mod.Index) -- $($mod.Name) (re-run)"
    $Script:StepStartTime = Get-Date
    Update-Wizard
    Start-ModuleInWindow -ModuleFile $mod.File -FunctionName $mod.Fn -State $Script:AutoState -LogBox $controls['LogAll'] -OnDone {
        param([bool]$ok)
        $idx = $Script:StepDefs[$Script:FailedIndex].Index
        Add-RunLogText $controls['LogAll'] "-- $(if ($ok) {'Completed'} else {'Failed'}) in $(Format-Elapsed ((Get-Date) - $Script:StepStartTime)) --`r`n"
        $controls['LogAll'].ScrollToEnd()
        Save-RunLog
        $Script:AutoState['RunSteps'] = @($Script:RunStepsAll)
        if (-not $ok) { Set-StepState -Index $idx -State 'Failed'; Stop-RunAtFailure -Index $idx; return }
        Set-StepState -Index $idx -State 'Done'
        $Script:RunDone++
        Update-RunProgress
        $Script:AutoIndex   = $Script:FailedIndex + 1
        $Script:FailedIndex = -1
        Run-NextAutoModule
    }
}
foreach ($s in ($Script:StepDefs | Where-Object { $_.Index -ne 13 })) { $controls["BtnRerun$($s.Index)"].Add_Click({ Start-StepRerun }) }
$controls['BtnFailRerun'].Add_Click({ Start-StepRerun })
$controls['BtnOpenLog'].Add_Click({
    $log = if ($Script:AutoState -and $Script:AutoState['RunRoot']) { Join-Path $Script:AutoState['RunRoot'] 'Logs\Wizard.log' } else { '' }
    if ($log -and (Test-Path -LiteralPath $log)) { Start-Process notepad.exe -ArgumentList "`"$log`"" }
})

# ---- Site DB fetch (Sign in page -> Next) --------------------------------------

# Called on the UI thread when the fetch finishes; fills the DOC drop-downs, reads this VM's DOC assignment and
# timeouts, and moves to the next page
function Complete-MachineFetch {
    param([object[]]$MachineList, [string]$ErrorText)
    $controls['BtnNext'].IsEnabled = $true
    $site = Get-SelectedSite
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
    $controls['TxtMachineCount'].Text        = "$($MachineList.Count) machines loaded from the $site Site DB at sign-in. DOC n = CNC n; only assigned machines are configured."

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
    # What this VM has now (read once): Component / Update and Verification start from it
    if (-not $Script:CurrentDOCRead) {
        try { $Script:CurrentDOC = Get-CurrentDOCAssignment -Manifest $Script:ViewManifest -MachineNames @($MachineList | ForEach-Object { $_.MachineName }) } catch { $Script:CurrentDOC = @{} }
        $Script:CurrentDOCRead = $true
        try { Read-DOCTimeouts } catch { }
        if ((Get-ConfigType) -ne 'initial') { Set-DOCFromVm }
    }
    Update-DOCRows
    $Script:PageIndex++
    Update-Wizard
    if ((Get-WizardPages)[$Script:PageIndex] -eq 'verify') { Start-Verification }
}

function Start-MachineFetch {
    $siteCode  = Get-SelectedSite
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
    $site = Get-SelectedSite
    if (-not $site) { Show-Warning 'Select a site.'; return $false }
    if (-not $controls['TxtSiteDBHost'].Text.Trim() -or -not $controls['TxtSiteDBUser'].Text.Trim() -or -not $controls['PwdSiteDB'].Password) {
        Show-Warning "Fill in the Site DB hostname, username and password." 'Missing Input'; return $false
    }
    $user = $controls['TxtUsername'].Text.Trim()
    $pwd  = $controls['PwdUserAccount'].Password
    if (-not $user -or -not $pwd) { Show-Warning 'Enter your domain username and password.' 'Credentials Required'; return $false }
    if ($user -notmatch '^[^\\]+\\[^\\]+$') { Show-Warning 'Username must include the domain: DOMAIN\username' 'Invalid Format'; return $false }
    $domain = [string]$manifest.ServiceAccounts.Domain
    $svc    = Get-SvcAccountName
    $window.Cursor = 'Wait'
    try {
        if (-not (Test-InstallerCredential -DomainUser $user -Password $pwd)) {
            [System.Windows.MessageBox]::Show("Sign-in failed for '$user'. Check your username and password.", 'Sign-in Failed', 'OK', 'Error') | Out-Null
            return $false
        }
        # The APC apps run as the site's service account, and per-user settings (DOC's OPC UA certificate) follow it
        if ($env:USERNAME -ine $svc -or $env:USERDOMAIN -ine $domain) {
            [System.Windows.MessageBox]::Show("Sign in to Windows as $domain\$svc to run the configuration.`n`nCurrent: $env:USERDOMAIN\$env:USERNAME",
                'Wrong Windows Account', 'OK', 'Error') | Out-Null
            return $false
        }
        # Initial System Configuration runs every step: all three passwords. Other types: the steps they run ask
        # for theirs at the start; whatever is entered is checked now.
        $need = (Get-ConfigType) -eq 'initial'
        $apc = $controls['PwdAPCUser'].Password; $pg = $controls['PwdPostgres'].Password; $sp = $controls['PwdSvcAccount'].Password
        if ($need -and (-not $apc -or -not $pg -or -not $sp)) { Show-Warning 'Enter the apcuser, PostgreSQL and service account passwords.' 'Passwords Required'; return $false }
        if ($apc -and (Test-StandardPassword -Password $apc -Check $manifest.PostgreSQL.LocalUserPasswordCheck) -eq $false) {
            [System.Windows.MessageBox]::Show('The apcuser password is not the standard APC password.', 'apcuser', 'OK', 'Error') | Out-Null; return $false
        }
        if ($pg -and -not (Test-PostgresPassword)) {
            [System.Windows.MessageBox]::Show('PostgreSQL did not accept the postgres password.', 'PostgreSQL', 'OK', 'Error') | Out-Null; return $false
        }
        if ($sp -and -not (Test-InstallerCredential -DomainUser "$domain\$svc" -Password $sp)) {
            [System.Windows.MessageBox]::Show("Sign-in failed for $domain\$svc.", 'Service Account', 'OK', 'Error') | Out-Null; return $false
        }
    } finally { $window.Cursor = $null }
    return $true
}

function Test-MachinesPage {
    $cnt   = Get-DOCCount
    $names = @(1..$cnt | ForEach-Object { Get-CHMIMachineName $_ })
    if ($names -contains '') { Show-Warning "Pick a machine for every DOC instance."; return $false }
    if (@($names | Sort-Object -Unique).Count -ne $names.Count) { Show-Warning "Each DOC instance needs a different machine."; return $false }
    foreach ($k in $Script:DOCTimeBoxes.Keys) {
        $box = $controls["TxtDOCTime$k"]
        if ($box.IsEnabled -and $box.Text.Trim() -notmatch '^[1-9]\d*$') { $controls['ExpDOCTimes'].IsExpanded = $true; Show-Warning 'DOC timeouts are whole seconds.'; return $false }
    }
    return $true
}

function Test-DataAppsPage {
    $activeInst = @(Get-DataAppsSelection -CncCount (Get-DOCCount) | Where-Object { $_.CNCs.Count -gt 0 })
    if ($activeInst.Count -eq 0) { Show-Warning "Tick at least one CNC for an instrument."; return $false }
    $noSource = @($activeInst | Where-Object { -not $_.SourcePath } | ForEach-Object { $_.Type })
    if ($noSource.Count -gt 0) { Show-Warning "Enter a results folder for: $($noSource -join ', ')"; return $false }
    return $true
}

# ---- The run's state ------------------------------------------------------------

# State for a run (Configure page) or a verification: its own folder <work folder>\<type>_<yyyyMMdd-HHmmss>, the page
# values, the operator's AD record and the install drive (a problem with it throws: the run does not start)
function New-RunState {
    param([string]$Type)
    $inst = Find-MedtronicInstall -Manifest $manifest
    if ($inst.Error) { throw "Medtronic install drive: $($inst.Error)`n`nFix the installation (Installation Manager) and start again." }
    $st = Get-CurrentState
    $runRoot = Join-Path $Script:ApcRoot ("{0}_{1}" -f $Script:ConfigTypes[$Type].Folder, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    foreach ($sub in 'Logs', 'Reports') { New-Item -ItemType Directory -Path (Join-Path $runRoot $sub) -Force -ErrorAction Stop | Out-Null }
    $st['RunRoot']        = $runRoot
    $st['ConfigType']     = $Type
    $st['ConfigTypeName'] = $Script:ConfigTypes[$Type].Name
    # Performed By (employee number) and the 'draft ready' e-mail: the operator's AD record, read once
    $ad = Get-OperatorAdInfo $st['OperatorName']
    $st['EmployeeNumber']    = $ad.EmployeeNumber
    $st['OperatorEmail']     = $ad.Mail
    $st['OperatorFirstName'] = $ad.GivenName
    $docCount = Get-DOCCount
    $st['CNCMachines']           = @($Global:FetchedMachines)
    $st['DOCMachineAssignments'] = @(1..$docCount | ForEach-Object { Get-CHMIMachineName $_ })
    $st['DataAppsInstruments']   = @(Get-DataAppsSelection -CncCount $docCount)
    $st['DataAppsLocalRoot']     = [string]$manifest.DataApps.LocalDataRoot
    $st['CNCnetPDMLicense']      = $controls['TxtLicense'].Text.Trim()
    $st['DOCTimeouts']           = Get-DOCTimeoutChanges
    if ('chmi' -in (Get-WizardPages)) { $st['800xASettings'] = Get-CHMISettingsState }
    foreach ($pair in @(@('APCUserPassword', 'PwdAPCUser'), @('PostgresPassword', 'PwdPostgres'), @('SvcAccountPassword', 'PwdSvcAccount'), @('SiteDBPassword', 'PwdSiteDB'))) {
        $st[$pair[0]] = $controls[$pair[1]].SecurePassword.Copy()
    }
    # Configuration Restore: the restored configuration's DOC assignment and page values (the backup's run state)
    if ($Type -eq 'restore' -and $Script:RestoreInfo) {
        $st['RestoreSource']     = $Script:RestoreInfo.Backups
        $st['RestoreComponents'] = @(Get-RestorePicks)
        $b = $Script:RestoreInfo.State
        if ($b) {
            foreach ($k in 'DOCCount', 'SINCEmail', 'CNCnetPDMLicense', 'DataAppsLocalRoot') { if ($b.PSObject.Properties[$k] -and $b.$k) { $st[$k] = $b.$k } }
            if ($b.PSObject.Properties['DOCMachineAssignments']) { $st['DOCMachineAssignments'] = @($b.DOCMachineAssignments) }
            if ($b.PSObject.Properties['DataAppsInstruments']) {
                $st['DataAppsInstruments'] = @($b.DataAppsInstruments | ForEach-Object { $h = @{}; foreach ($pp in $_.PSObject.Properties) { $h[$pp.Name] = $pp.Value }; $h })
            }
        }
    }
    # The Medtronic apps may be on C: or D: (Installation Manager): the run's <X>:\Medtronic paths follow that drive
    $Script:RunManifest = Set-ManifestMedtronicDrive -Manifest $manifest -Drive $inst.Drive
    Set-StateMedtronicDrive -State $st -Drive $inst.Drive
    $st['InstallApps'] = "Medtronic apps on $($inst.Drive): " + (($inst.Apps | ForEach-Object { "$($_.Name) ($($_.Source))" }) -join ', ') +
                         $(if ($inst.Missing) { "; not installed: $($inst.Missing -join ', ')" })
    return $st
}

function Start-ConfigurationRun {
    $type     = Get-ConfigType
    $runSteps = @(Get-PlanSteps)
    if (2 -in $runSteps -and (-not $controls['PwdAPCUser'].Password -or -not $controls['PwdPostgres'].Password)) {
        Show-Warning "Enter the apcuser and PostgreSQL passwords on the Sign in page - TimescaleDB (step 2) needs them." 'Password Required'; return $false
    }
    if (11 -in $runSteps -and [bool]$manifest.CHMI.AutomateCertificates -and -not $controls['PwdSvcAccount'].Password) {
        Show-Warning "Enter the $(Get-SvcAccountName) password on the Sign in page - CHMI (step 11) updates the 800xA certificates with it." 'Password Required'; return $false
    }
    if (7 -in $runSteps -and -not $controls['TxtLicense'].Text.Trim()) {
        Show-Warning "Enter the CNCnetPDM license key or tick 'Use default perpetual license'."; return $false
    }
    if (10 -in $runSteps -and -not (Test-DataAppsPage)) { return $false }
    if (11 -in $runSteps -and 'chmi' -in (Get-WizardPages) -and -not (Test-CHMIPage)) { return $false }

    try { $Script:AutoState = New-RunState -Type $type }
    catch { [System.Windows.MessageBox]::Show("$($_.Exception.Message)", $Script:AppName, 'OK', 'Error') | Out-Null; return $false }
    # CNCAsset / CNCType are written once, by the run's last step that restarts dwcore (Set-DwCncAssetAfterRestarts)
    $Script:AutoState['RunSteps'] = @($runSteps)
    $Script:RunStepsAll = @($runSteps)
    $Script:FailedIndex = -1
    $Script:VerifyStarted = $false; $Script:Drafted = $false   # the last page verifies this run
    $controls['TxtReportPath'].Visibility = 'Collapsed'; $controls['TxtReportMail'].Visibility = 'Collapsed'
    $controls['BtnOpenReport'].IsEnabled  = $false
    Save-State -State $Script:AutoState

    foreach ($s in ($Script:StepDefs | Where-Object { $_.Index -ne 13 })) {
        $n = $s.Index
        $controls["RowStep$n"].Visibility = if ($n -in $runSteps) { 'Visible' } else { 'Collapsed' }
        Set-StepState -Index $n -State 'Pending'
    }
    $Script:RunTotal  = $runSteps.Count
    $Script:RunDone   = 0
    $Script:AutoIndex = 0
    $controls['PanelFail'].Visibility    = 'Collapsed'
    $controls['PanelRunDone'].Visibility = 'Collapsed'
    $controls['TxtRunFolder'].Text = "Logs, backups and reports of this run: $($Script:AutoState['RunRoot'])\"
    $controls['LogAll'].Text = ''
    Add-RunLogText $controls['LogAll'] ("{0} {1} - {2} - {3} - started {4} by {5} (Windows: {6}\{7})`r`nRelease: {8}`r`nSteps: {9}`r`nRun folder: {10}`r`n{11}`r`n" -f
        $Script:AppName, $Script:AppVersion, $Script:ConfigTypes[$type].Name, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $Script:AutoState['OperatorName'], $env:USERDOMAIN, $env:USERNAME, $Script:Release.ReleaseLabel, ($runSteps -join ', '),
        $Script:AutoState['RunRoot'], $Script:AutoState['InstallApps'])
    if ($Script:Release.Problem) { Add-RunLogText $controls['LogAll'] "Release workbook: $($Script:Release.Problem) - using $($Script:Release.ReleaseLabel) from the manifest`r`n" }
    Update-RunProgress
    return $true
}

# ---- Verification & report (Step 13 on the last page) -----------------------------------

function Get-ReportState {
    # After a run: the run's state. Verification: its own run folder, with this VM's DOC assignment
    if (-not $Script:AutoState) {
        $Script:AutoState = New-RunState -Type (Get-ConfigType)
        $Script:AutoState['RunSteps'] = @()
        Add-RunLogText $controls['LogVerification'] ("{0} {1} - Verification - {2} - {3} by {4}`r`nRun folder: {5}`r`n{6}`r`n" -f
            $Script:AppName, $Script:AppVersion, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Script:AutoState['OperatorName'],
            $Script:AutoState['RunRoot'], $Script:AutoState['InstallApps'])
        Save-State -State $Script:AutoState
    }
    $Script:AutoState['SkipDraft'] = $true   # the draft is its own button, after the checklist details
    $Script:AutoState
}

function Set-VerifyBusy([bool]$On) {
    $Script:Busy = $On
    Update-Wizard
}

function Start-Verification {
    $Script:VerifyStarted = $true
    try { $st = Get-ReportState }
    catch { [System.Windows.MessageBox]::Show("$($_.Exception.Message)", $Script:AppName, 'OK', 'Error') | Out-Null; return }
    foreach ($n in 'TxtPassCount', 'TxtWarnCount', 'TxtFailCount', 'TxtManualCount') { $controls[$n].Text = '-' }
    $controls['TxtVerifyStatus'].Text = 'Running...'
    Add-RunLogText $controls['LogVerification'] "`r`n== Verification $(Get-Date -Format 'HH:mm:ss') ==`r`n"
    Set-VerifyBusy $true
    Start-ModuleInWindow -ModuleFile '13-Verification.ps1' -FunctionName 'Invoke-Verification' -State $st -LogBox $controls['LogVerification'] -OnDone {
        param([bool]$ok)
        $c = $Script:AutoState['VerificationCounts']
        if ($c) {
            $controls['TxtPassCount'].Text = [string]$c.Pass;  $controls['TxtWarnCount'].Text   = [string]$c.Warn
            $controls['TxtFailCount'].Text = [string]$c.Fail;  $controls['TxtManualCount'].Text = [string]$c.Manual
        }
        $controls['TxtVerifyStatus'].Text = if (-not $c) { 'Did not finish - see details' } else { "Ran $(Get-Date -Format 'HH:mm')" }
        Set-VerifyBusy $false
    }
}
$controls['BtnRunVerification'].Add_Click({ Start-Verification })

$controls['BtnGenerateReport'].Add_Click({
    $st = $Script:AutoState
    if (-not $st -or -not $st['VerificationChecks']) { Show-Warning 'Run the verification first.'; return }
    if ((Get-ConfigType) -eq 'verify') {
        $reason = 'verify'
        foreach ($id in 'initial', 'restore', 'component', 'sysupdate', 'verify') { if ($controls["RbReason_$id"].IsChecked) { $reason = $id } }
        $st['ReasonType']        = $reason
        $st['ConfigReasonOther'] = if ($reason -eq 'verify') { $Script:VerifyReasonOther } else { '' }
    } else { $st['ReasonType'] = ''; $st['ConfigReasonOther'] = '' }
    $st['ChangeID']       = $controls['TxtChangeID'].Text.Trim()
    $st['DocumentNumber'] = $controls['TxtDocNumber'].Text.Trim()
    $st['IVRDocumentId']  = $controls['TxtIVRDocId'].Text.Trim()
    $st['ITTicket']       = $controls['TxtITTicket'].Text.Trim()
    $st['VerificationDocPath'] = $null
    $controls['TxtReportStatus'].Text = 'Creating...'
    Add-RunLogText $controls['LogReport'] "`r`n== Draft checklist $(Get-Date -Format 'HH:mm:ss') ==`r`n"
    Set-VerifyBusy $true
    Start-ModuleInWindow -ModuleFile '13-Verification.ps1' -FunctionName 'Invoke-ChecklistDraft' -State $st -LogBox $controls['LogReport'] -OnDone {
        param([bool]$ok)
        $doc = $Script:AutoState['VerificationDocPath']
        $controls['TxtReportStatus'].Text = ''
        if ($doc) {
            $Script:Drafted = $true
            $controls['BtnOpenReport'].IsEnabled = $true
            $controls['TxtReportPath'].Text = "$([char]0x2713) Draft saved to $doc"
            $controls['TxtReportPath'].Visibility = 'Visible'
            $controls['TxtReportMail'].Text = if ($Script:AutoState['OperatorEmail']) { "E-mailed to you ($($Script:AutoState['OperatorEmail'])): draft checklist ready for review." } else { 'No e-mail: no address in AD for your account.' }
            $controls['TxtReportMail'].Visibility = 'Visible'
            Save-State -State $Script:AutoState
        } else {
            $controls['TxtReportStatus'].Text = 'The draft was not created - see the log'
            $controls['TxtReportStatus'].Foreground = '#EF4444'
        }
        Set-VerifyBusy $false
    }
})

$controls['BtnOpenReport'].Add_Click({
    $doc = if ($Script:AutoState) { $Script:AutoState['VerificationDocPath'] } else { $null }
    if (-not $doc -or -not (Test-Path $doc)) {
        $reports = if ($Script:AutoState -and $Script:AutoState['RunRoot']) { Join-Path $Script:AutoState['RunRoot'] 'Reports' } else { (Join-Path $Script:ApcRoot 'Reports') }
        $doc = Get-ChildItem $reports -Filter 'APC_Config_Checklist_DRAFT_*.docx' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($doc) { Start-Process $doc }
})

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
        'restore'  { if (-not (Test-RestorePage)) { return } }
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
    if ((Get-WizardPages)[$Script:PageIndex] -eq 'verify' -and -not $Script:VerifyStarted) { Start-Verification }
})

$controls['CmbSiteCode'].SelectedIndex = 0
Update-SiteDBFields
Update-DataAppsDefaults
$controls['CmbSiteCode'].Add_SelectionChanged({ Update-SiteDBFields; Update-DataAppsDefaults; Update-Wizard })
Update-DOCRows
if ($Script:Release.Problem) { Write-Host "Release workbook: $($Script:Release.Problem) - using $($Script:Release.ReleaseLabel) from the manifest" -ForegroundColor Yellow }
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
