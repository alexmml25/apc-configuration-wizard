#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    APC Configuration Deployment Wizard - GUI Entry Point
.DESCRIPTION
    WPF wizard that configures the APC system (D01555607) after installation.
    Fill in Setup, fetch machines from Site DB, then click Configure.
    Modules 01-13 run automatically. CHMI steps (11) include a manual pause.
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

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="APC Configuration Deployment Wizard"
    Width="860" Height="700"
    MinWidth="720" MinHeight="580"
    WindowStartupLocation="CenterScreen"
    FontFamily="Segoe UI" FontSize="13"
    Background="#FFFFFF">

  <Window.Resources>
    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Padding"         Value="16,8"/>
      <Setter Property="Margin"          Value="4,0"/>
      <Setter Property="FontSize"        Value="13"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
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
    </Style>
    <Style x:Key="SecondaryBtn" TargetType="Button" BasedOn="{StaticResource NavBtn}">
      <Setter Property="Background" Value="#F1F5F9"/>
      <Setter Property="Foreground" Value="#475569"/>
    </Style>
    <Style x:Key="GreenBtn" TargetType="Button" BasedOn="{StaticResource NavBtn}">
      <Setter Property="Background" Value="#166534"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
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
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground"    Value="#475569"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin"        Value="0,0,0,8"/>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Padding"          Value="6"/>
      <Setter Property="Margin"           Value="0,0,0,8"/>
      <Setter Property="BorderBrush"      Value="#E2E8F0"/>
      <Setter Property="BorderThickness"  Value="1"/>
    </Style>
    <Style x:Key="Pwd" TargetType="PasswordBox">
      <Setter Property="Padding"          Value="6"/>
      <Setter Property="Margin"           Value="0,0,0,8"/>
      <Setter Property="BorderBrush"      Value="#E2E8F0"/>
      <Setter Property="BorderThickness"  Value="1"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="64"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#f0f0f0">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
        <Image x:Name="ImgLogo" Width="150" Height="150" Stretch="Uniform" Margin="0,0,35,0"/>
        <TextBlock Text="APC Configuration Deployment Wizard" FontSize="20" FontWeight="SemiBold"
                   Foreground="Black" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>

    <!-- Scrollable content -->
    <ScrollViewer Grid.Row="1" x:Name="MainScroller"
                  VerticalScrollBarVisibility="Auto" Background="#F8FAFC">
      <StackPanel Margin="32,24,32,32">

        <!-- ===== SETUP ===== -->
        <StackPanel x:Name="PanelSetup">
          <TextBlock Text="Setup" FontSize="15" FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,12"/>

          <!-- Row 1: Installer Login + Site DB -->
          <Grid Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Installer Login -->
            <Border Grid.Column="0" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,12">Installer Login</TextBlock>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Username" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtUsername" Grid.Row="0" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="1" Text="Password" Style="{StaticResource Label}"/>
                  <PasswordBox x:Name="PwdUserAccount" Grid.Row="1" Grid.Column="1" Style="{StaticResource Pwd}"/>
                  <TextBlock Grid.Row="2" Text="Site" Style="{StaticResource Label}" Margin="0,0,0,0"/>
                  <ComboBox  x:Name="CmbSiteCode" Grid.Row="2" Grid.Column="1" Padding="6,5" BorderBrush="#E2E8F0"/>
                </Grid>
              </StackPanel>
            </Border>

            <!-- Site DB Connection -->
            <Border Grid.Column="2" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,12">Site Database</TextBlock>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Hostname" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtSiteDBHost" Grid.Row="0" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="1" Text="Username" Style="{StaticResource Label}"/>
                  <TextBox   x:Name="TxtSiteDBUser" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}"/>
                  <TextBlock Grid.Row="2" Text="Password" Style="{StaticResource Label}" Margin="0,0,0,0"/>
                  <PasswordBox x:Name="PwdSiteDB" Grid.Row="2" Grid.Column="1" Style="{StaticResource Pwd}" Margin="0,0,0,0"/>
                </Grid>
              </StackPanel>
            </Border>
          </Grid>

          <!-- Row 2: Component Passwords (full width) -->
          <Border Margin="0,0,0,14" Background="#FFFBEB" BorderBrush="#FDE68A" BorderThickness="1" CornerRadius="8" Padding="16">
            <StackPanel>
              <TextBlock FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,4">Component Passwords</TextBlock>
              <TextBlock FontSize="11" Foreground="#92400E" TextWrapping="Wrap" Margin="0,0,0,12">
                In memory only  -  never written to disk or logs.
              </TextBlock>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto" MinWidth="110"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="32"/>
                  <ColumnDefinition Width="Auto" MinWidth="110"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="apcuser (local)" Style="{StaticResource Label}"
                           ToolTip="Password for the local TimescaleDB apcuser role created in Step 2."/>
                <PasswordBox x:Name="PwdAPCUser" Grid.Column="2" Style="{StaticResource Pwd}"
                             ToolTip="Password for the local TimescaleDB apcuser role (Step 2)"/>
                <TextBlock Grid.Column="4" Text="MedtronicSU" Style="{StaticResource Label}"
                           ToolTip="Password for the MedtronicSU OPC UA user created in deviceWise Gateway (Step 4)"/>
                <PasswordBox x:Name="PwdMedtronicSU" Grid.Column="6" Style="{StaticResource Pwd}"
                             ToolTip="Password for the MedtronicSU OPC UA user (Step 4)"/>
              </Grid>
            </StackPanel>
          </Border>

          <!-- Proceed button -->
          <StackPanel Orientation="Horizontal" Margin="0,0,0,24">
            <Button x:Name="BtnProceed" Style="{StaticResource PrimaryBtn}"
                    Padding="20,10" FontSize="13" Content="Proceed to Configuration Options  >>"/>
            <TextBlock x:Name="TxtProceedStatus" VerticalAlignment="Center" Margin="12,0,0,0"
                       FontSize="12" Foreground="#64748B"/>
          </StackPanel>
        </StackPanel>

        <!-- ===== CONFIGURATION OPTIONS (collapsed until proceed succeeds) ===== -->
        <StackPanel x:Name="PanelConfigOptions" Visibility="Collapsed" Margin="0,0,0,0">
          <TextBlock Text="Configuration Options" FontSize="15" FontWeight="SemiBold"
                     Foreground="#1C2136" Margin="0,0,0,12"/>

          <!-- Hidden DataGrid (keeps binding working, not shown) -->
          <DataGrid x:Name="DgMachines" Visibility="Collapsed" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Machine Name" Binding="{Binding MachineName}"/>
              <DataGridTextColumn Header="IP Address"   Binding="{Binding IPAddress}"/>
              <DataGridTextColumn Header="Port"         Binding="{Binding Port}"/>
              <DataGridTextColumn Header="CNC Type"     Binding="{Binding AssetFamily}"/>
              <DataGridTextColumn Header="DLL"          Binding="{Binding DLLName}"/>
            </DataGrid.Columns>
          </DataGrid>
          <TextBlock x:Name="TxtMachineCount" Visibility="Collapsed"/>

          <!-- DOC options (all in one card) -->
          <Border Style="{StaticResource Card}" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,12">DOC Configuration</TextBlock>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="120"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Grid.Column="0" Text="DOC Instances" Style="{StaticResource Label}"/>
                <ComboBox  x:Name="CmbDOCCount" Grid.Row="0" Grid.Column="1" Padding="6,5" BorderBrush="#E2E8F0" Margin="0,0,0,8" HorizontalAlignment="Left" Width="120">
                  <ComboBoxItem Content="1"/>
                  <ComboBoxItem Content="2"/>
                  <ComboBoxItem Content="3" IsSelected="True"/>
                </ComboBox>

                <Grid x:Name="GridDOCRow1" Grid.Row="1" Grid.ColumnSpan="2">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="120"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="DOC Instance 1" Style="{StaticResource Label}" Margin="0,0,0,8"/>
                  <ComboBox x:Name="CmbDOCMachine1" Grid.Column="1" Padding="6,5" BorderBrush="#E2E8F0" Margin="0,0,0,8"/>
                </Grid>

                <Grid x:Name="GridDOCRow2" Grid.Row="2" Grid.ColumnSpan="2" Visibility="Collapsed">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="120"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="DOC Instance 2" Style="{StaticResource Label}" Margin="0,0,0,8"/>
                  <ComboBox x:Name="CmbDOCMachine2" Grid.Column="1" Padding="6,5" BorderBrush="#E2E8F0" Margin="0,0,0,8"/>
                </Grid>

                <Grid x:Name="GridDOCRow3" Grid.Row="3" Grid.ColumnSpan="2" Visibility="Collapsed">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="120"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="DOC Instance 3" Style="{StaticResource Label}" Margin="0,0,0,8"/>
                  <ComboBox x:Name="CmbDOCMachine3" Grid.Column="1" Padding="6,5" BorderBrush="#E2E8F0" Margin="0,0,0,8"/>
                </Grid>
              </Grid>
            </StackPanel>
          </Border>

          <!-- SINC Configuration -->
          <Border Style="{StaticResource Card}" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,12">SINC Configuration</TextBlock>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="120"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Alert Email" Style="{StaticResource Label}" VerticalAlignment="Top" Margin="0,4,0,8"/>
                <TextBox x:Name="TxtSINCEmail" Grid.Column="1" Style="{StaticResource Input}"
                         ToolTip="Semicolon-separated email addresses for SINC alerts"/>
              </Grid>
            </StackPanel>
          </Border>

          <!-- Start from step (for testing / partial re-runs) -->
          <StackPanel Orientation="Horizontal" Margin="0,0,0,14">
            <TextBlock Text="Start from step" Style="{StaticResource Label}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="CmbStartStep" Padding="6,5" BorderBrush="#E2E8F0" Width="70">
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
            <TextBlock Text="(skip earlier steps - for testing only)" Foreground="#94A3B8"
                       FontSize="11" VerticalAlignment="Center" Margin="8,0,0,0"/>
          </StackPanel>

          <!-- Configure button -->
          <Button x:Name="BtnConfigure" HorizontalAlignment="Left"
                  Padding="28,12" FontSize="14" FontWeight="SemiBold"
                  Cursor="Hand" BorderThickness="0" Background="#4361EE" Foreground="White" IsEnabled="False"
                  ToolTip="Complete the options above, then click to begin configuration">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="BtnBd" Background="{TemplateBinding Background}" CornerRadius="7"
                        Padding="{TemplateBinding Padding}">
                  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsEnabled" Value="False">
                    <Setter TargetName="BtnBd" Property="Background" Value="#94A3B8"/>
                    <Setter TargetName="BtnBd" Property="Opacity"    Value="0.7"/>
                  </Trigger>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="BtnBd" Property="Background" Value="#3451D1"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
            &gt;&gt;  Configure APC System
          </Button>
        </StackPanel>

        <!-- ===== CONFIGURATION PROGRESS ===== -->
        <StackPanel x:Name="PanelProgress" Visibility="Collapsed" Margin="0,24,0,0">
          <TextBlock Text="Configuration Progress" FontSize="15" FontWeight="SemiBold"
                     Foreground="#1C2136" Margin="0,0,0,12"/>

          <!-- Step status card -->
          <Border Style="{StaticResource Card}" Margin="0,0,0,12" Padding="14,10">
            <StackPanel>

              <!-- Step row template (repeated 13 times) -->
              <!-- Step 1 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 1" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="Site DB Fetch" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep1Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep1Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun1"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 2 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 2" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="TimescaleDB Setup" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep2Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep2Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun2"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 3 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 3" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="SINC Folder Structure" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep3Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep3Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun3"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 4 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 4" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="deviceWise Base Platform" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep4Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep4Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun4"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 5 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 5" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="deviceWise CHMI Integration" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep5Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep5Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun5"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 6 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 6" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="deviceWise SINC Integration" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep6Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep6Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun6"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 7 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 7" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="deviceWise CNCnetPDM Integration" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep7Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep7Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun7"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 8 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 8" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="CNCnetPDM Configuration" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep8Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep8Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun8"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 9 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 9" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="DOC XML Configuration" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep9Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep9Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun9"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 10 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 10" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="Data Applications Config" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep10Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep10Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun10"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 11 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 11" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="CHMI / APC UI OPC UA" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep11Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep11Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun11"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 12 -->
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 12" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="Application Backup" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep12Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep12Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun12"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>
              <Separator Margin="0,0,0,8" Background="#E2E8F0"/>

              <!-- Step 13 -->
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="22"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Step 13" FontSize="11" Foreground="#94A3B8" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="Verification &amp; Report" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#1C2136"/>
                <TextBlock x:Name="TxtStep13Status" Grid.Column="2" Text="Pending" VerticalAlignment="Center" Foreground="#94A3B8" FontSize="12" Margin="0,0,6,0"/>
                <TextBlock x:Name="TxtStep13Icon"   Grid.Column="3" Text="o" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#94A3B8"/>
                <Button    x:Name="BtnRerun13"       Grid.Column="4" Content="Re-run" Style="{StaticResource SecondaryBtn}" Visibility="Collapsed" Margin="8,0,0,0" Padding="10,3"/>
              </Grid>

            </StackPanel>
          </Border>

          <!-- Progress bar -->
          <Grid Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <ProgressBar x:Name="BarOverall" Height="10" Minimum="0" Maximum="13" Value="0"
                         Foreground="#4361EE" Background="#E2E8F0" BorderThickness="0"/>
            <TextBlock x:Name="TxtProgressLabel" Grid.Column="2" Text="0 / 13"
                       FontSize="12" Foreground="#64748B" VerticalAlignment="Center"/>
          </Grid>

          <!-- Combined log -->
          <TextBox x:Name="LogAll" Style="{StaticResource LogBox}" Height="260" MinHeight="0"/>
        </StackPanel>

        <!-- ===== POST-CONFIG ===== -->
        <StackPanel x:Name="PanelPostConfig" Visibility="Collapsed" Margin="0,24,0,0">
          <TextBlock Text="Post-Configuration" FontSize="15" FontWeight="SemiBold"
                     Foreground="#1C2136" Margin="0,0,0,12"/>

          <!-- Verification -->
          <Border Style="{StaticResource Card}" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,10">Configuration Verification</TextBlock>
              <TextBlock TextWrapping="Wrap" Foreground="#475569" FontSize="12" Margin="0,0,0,10">
                Checks services, ports, ODBC DSN, and component connectivity.
              </TextBlock>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnRunVerification" Style="{StaticResource PrimaryBtn}" Content="Run Verification"/>
                <TextBlock x:Name="TxtVerificationStatus" VerticalAlignment="Center"
                           Margin="12,0,0,0" FontSize="12" Foreground="#64748B"/>
              </StackPanel>
              <TextBox x:Name="LogVerification" Style="{StaticResource LogBox}"
                       Visibility="Collapsed" Margin="0,10,0,0" MinHeight="120"/>
            </StackPanel>
          </Border>

          <!-- Report -->
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock FontWeight="SemiBold" Foreground="#1C2136" Margin="0,0,0,10">Configuration Report</TextBlock>
              <Grid Margin="0,0,0,12">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="130"/><ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="Reviewer Name" Style="{StaticResource Label}"/>
                <TextBox   x:Name="TxtReviewerName" Grid.Row="0" Grid.Column="1" Style="{StaticResource Input}"/>
                <TextBlock Grid.Row="1" Text="Reviewer Role" Style="{StaticResource Label}"/>
                <TextBox   x:Name="TxtReviewerRole" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}"/>
                <TextBlock Grid.Row="2" Text="Decision" Style="{StaticResource Label}" Margin="0,0,0,0"/>
                <ComboBox  x:Name="CmbDecision" Grid.Row="2" Grid.Column="1" Padding="6,5" BorderBrush="#E2E8F0">
                  <ComboBoxItem Content="APPROVED" IsSelected="True"/>
                  <ComboBoxItem Content="REJECTED - Issues require resolution"/>
                </ComboBox>
              </Grid>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnGenerateReport" Style="{StaticResource PrimaryBtn}" Content="Generate Report"/>
                <Button x:Name="BtnOpenReport" Style="{StaticResource SecondaryBtn}"
                        Content="Open Report" Visibility="Collapsed" Margin="8,0,0,0"/>
                <TextBlock x:Name="TxtReportStatus" VerticalAlignment="Center"
                           Margin="12,0,0,0" FontSize="12" Foreground="#64748B"/>
              </StackPanel>
              <TextBox x:Name="LogReport" Style="{StaticResource LogBox}"
                       Visibility="Collapsed" Margin="0,10,0,0" MinHeight="100"/>
              <TextBlock x:Name="TxtReportPath" Margin="0,8,0,0" Foreground="#166534"
                         FontFamily="Consolas" FontSize="11" Visibility="Collapsed" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>
        </StackPanel>

      </StackPanel>
    </ScrollViewer>
  </Grid>
</Window>
'@

# Build window
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$controls = @{}
$xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $controls[$_.Name] = $window.FindName($_.Name)
}

# Logo
$logoPath = Join-Path $Script:RootDir 'APC Logo.png'
if (Test-Path $logoPath) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource   = [Uri]::new($logoPath, [System.UriKind]::Absolute)
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $controls['ImgLogo'].Source = $bmp
}

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

$controls['CmbSiteCode'].Add_SelectionChanged({ Update-SiteDBFields })

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

$controls['CmbDOCCount'].Add_SelectionChanged({
    if ($controls['PanelConfigOptions'].Visibility -ne 'Visible') { return }
    $cnt = if ($controls['CmbDOCCount'].SelectedItem) { [int]$controls['CmbDOCCount'].SelectedItem.Content } else { 3 }
    $controls['GridDOCRow2'].Visibility = if ($cnt -ge 2) { 'Visible' } else { 'Collapsed' }
    $controls['GridDOCRow3'].Visibility = if ($cnt -ge 3) { 'Visible' } else { 'Collapsed' }
    Update-DOCMachineChoices
})

foreach ($n in 1,2,3) {
    $controls["CmbDOCMachine$n"].Add_SelectionChanged({ Update-DOCMachineChoices })
}
$controls['CmbSiteCode'].SelectedIndex = 0
Update-SiteDBFields

# Step definitions
$Script:StepDefs = @(
    @{ Index =  1; Name = 'Site DB Fetch';                  File = '01-SiteDBFetch.ps1';      Fn = 'Invoke-SiteDBFetch'       },
    @{ Index =  2; Name = 'TimescaleDB Setup';              File = '02-TimescaleDB.ps1';      Fn = 'Invoke-TimescaleDBSetup'  },
    @{ Index =  3; Name = 'SINC Folder Structure';          File = '03-SINCFolders.ps1';      Fn = 'Invoke-SINCFolders'       },
    @{ Index =  4; Name = 'deviceWise Base Platform';       File = '04-DeviceWiseBase.ps1';   Fn = 'Invoke-DeviceWiseBase'    },
    @{ Index =  5; Name = 'deviceWise CHMI Integration';    File = '05-DeviceWiseCHMI.ps1';   Fn = 'Invoke-DeviceWiseCHMI'    },
    @{ Index =  6; Name = 'deviceWise SINC Integration';    File = '06-DeviceWiseSINC.ps1';   Fn = 'Invoke-DeviceWiseSINC'    },
    @{ Index =  7; Name = 'deviceWise CNCnetPDM Integrate'; File = '07-DeviceWiseCNCPDM.ps1'; Fn = 'Invoke-DeviceWiseCNCPDM'  },
    @{ Index =  8; Name = 'CNCnetPDM Configuration';        File = '08-CNCnetPDM.ps1';        Fn = 'Invoke-CNCnetPDMConfig'   },
    @{ Index =  9; Name = 'DOC XML Configuration';          File = '09-DOCConfig.ps1';        Fn = 'Invoke-DOCConfig'         },
    @{ Index = 10; Name = 'Data Applications Config';       File = '10-DataApps.ps1';         Fn = 'Invoke-DataAppsConfig'    },
    @{ Index = 11; Name = 'CHMI / APC UI OPC UA';           File = '11-CHMI.ps1';             Fn = 'Invoke-CHMIConfig'        },
    @{ Index = 12; Name = 'Application Backup';             File = '12-Backup.ps1';           Fn = 'Invoke-ApplicationBackup' },
    @{ Index = 13; Name = 'Verification & Report';          File = '13-Verification.ps1';     Fn = 'Invoke-ConfigVerification'}
)

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
        'Skipped' { $icon.Text = '-';                  $icon.Foreground = '#CBD5E1'; $status.Text = 'Skipped';    $status.Foreground = '#CBD5E1'; $rerun.Visibility = 'Collapsed' }
    }
}

function Get-CurrentState {
    $site    = if ($controls['CmbSiteCode'].SelectedItem)  { $controls['CmbSiteCode'].SelectedItem.Content  } else { '' }
    $docItem = if ($controls['CmbDOCCount'].SelectedItem)  { $controls['CmbDOCCount'].SelectedItem.Content  } else { '3' }
    return @{
        CurrentPhase     = 1
        OperatorName     = $controls['TxtUsername'].Text.Trim()
        OperatorRole     = 'Service Account'
        SiteCode         = $site
        SiteDBHost       = $controls['TxtSiteDBHost'].Text.Trim()
        SiteDBUser       = $controls['TxtSiteDBUser'].Text.Trim()
        SINCEmail        = $controls['TxtSINCEmail'].Text.Trim()
        DOCCount         = [int]$docItem
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
    $safe | ConvertTo-Json -Depth 10 | Set-Content $Script:StateFile -Encoding UTF8
}

function Add-LogSection {
    param([string]$Title)
    $bar = '=' * 58; $pad = ' ' * ([math]::Max(0, (58 - $Title.Length - 4)) / 2)
    $controls['LogAll'].AppendText("`r`n$bar`r`n$pad  $Title`r`n$bar`r`n")
    $controls['LogAll'].ScrollToEnd()
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
    $rs.SessionStateProxy.SetVariable('_manifest', $manifest)
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
$Global:FetchedMachines = @()

function Run-NextAutoModule {
    if ($Script:AutoIndex -ge $Script:StepDefs.Count) {
        $n = $Script:StepDefs.Count
        $controls['TxtProgressLabel'].Text       = "$n / $n"
        $controls['BarOverall'].Value            = $n
        $controls['BtnConfigure'].IsEnabled      = $true
        $controls['PanelPostConfig'].Visibility  = 'Visible'
        $controls['MainScroller'].ScrollToEnd()
        [System.Windows.MessageBox]::Show(
            "All 13 configuration steps complete.`n`nProceed to Post-Configuration below: run Verification and generate the Configuration Report.",
            "Configuration Complete", "OK", "Information") | Out-Null
        return
    }

    $mod = $Script:StepDefs[$Script:AutoIndex]
    Add-LogSection -Title "Step $($mod.Index) -- $($mod.Name)"
    Set-StepState -Index $mod.Index -State 'Running'
    $controls['TxtProgressLabel'].Text = "$($Script:AutoIndex) / $($Script:StepDefs.Count)"
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

            # Step 11 (CHMI) uses Paused state when manual steps are required
            if ($doneIndex -eq 11 -and $Script:RSSync.Paused) {
                Set-StepState -Index $doneIndex -State 'Paused'
            } else {
                Set-StepState -Index $doneIndex -State $(if ($ok) { 'Done' } else { 'Failed' })
            }
            $controls['BarOverall'].Value = $Script:AutoIndex + 1

            if (-not $ok) {
                $modName = $Script:StepDefs[$Script:AutoIndex].Name
                $choice  = [System.Windows.MessageBox]::Show(
                    "$modName reported errors - see log.`n`nContinue to next step?",
                    "Step Failed", "YesNo", "Warning")
                if ($choice -ne 'Yes') {
                    $controls['BtnConfigure'].IsEnabled = $true; return
                }
            }
            $Script:AutoIndex++
            Run-NextAutoModule
        }
}

# ---- Proceed button ---------------------------------------------------------

$controls['BtnProceed'].Add_Click({
    $siteCode  = if ($controls['CmbSiteCode'].SelectedItem) { $controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    $dbHost    = $controls['TxtSiteDBHost'].Text.Trim()
    $dbUser    = $controls['TxtSiteDBUser'].Text.Trim()
    $dbPwd     = $controls['PwdSiteDB'].Password

    if (-not $siteCode -or -not $dbHost -or -not $dbUser -or -not $dbPwd) {
        [System.Windows.MessageBox]::Show("Fill in Site Code, Site DB hostname, username, and password.", "Missing Input", "OK", "Warning") | Out-Null
        return
    }

    $controls['BtnProceed'].IsEnabled         = $false
    $controls['TxtProceedStatus'].Text        = 'Connecting to Site DB...'
    $controls['TxtProceedStatus'].Foreground  = '#4361EE'

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
            $idx = 1
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
                        DeviceNr    = $idx
                    }
                    $idx++
                }
            }
            $_sync.Machines = $machines
            $_sync.Done     = $true
        } catch {
            $_sync.Error = $_.Exception.Message
            $_sync.Done  = $true
        }
    })
    $handle   = $ps.BeginInvoke()
    $capSync  = $fetchSync; $capPS = $ps; $capRS = $rs; $capHandle = $handle
    $capControls  = $controls
    $capUpdateDOC = ${function:Update-DOCMachineChoices}

    $fetchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $fetchTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $fetchTimer.Add_Tick({
        if (-not $capSync.Done) { return }
        $args[0].Stop()
        try { $capPS.EndInvoke($capHandle) } catch {}
        $capRS.Close()

        $capControls['BtnProceed'].IsEnabled = $true
        if ($capSync.Error) {
            $capControls['TxtProceedStatus'].Text       = "Error: $($capSync.Error)"
            $capControls['TxtProceedStatus'].Foreground = '#EF4444'
            [System.Windows.MessageBox]::Show("Site DB query failed:`n$($capSync.Error)", "Fetch Error", "OK", "Error") | Out-Null
            return
        }

        $machineList = $capSync.Machines
        if (-not $machineList -or $machineList.Count -eq 0) {
            $capControls['TxtProceedStatus'].Text       = "No machines found for site $($capControls['CmbSiteCode'].SelectedItem.Content)"
            $capControls['TxtProceedStatus'].Foreground = '#D97706'
            return
        }

        # Populate DataGrid
        $col = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        foreach ($m in $machineList) { $col.Add($m) }
        $capControls['DgMachines'].ItemsSource   = $col
        $capControls['TxtMachineCount'].Text     = "$($machineList.Count) machine(s) loaded from Site DB"
        $capControls['TxtProceedStatus'].Text    = "$($machineList.Count) machine(s) - scroll down to configure"
        $capControls['TxtProceedStatus'].Foreground = '#166534'

        # Populate DOC machine dropdowns; default each to a different machine
        foreach ($n in 1,2,3) {
            $cmb = $capControls["CmbDOCMachine$n"]
            $cmb.Items.Clear()
            foreach ($m in $machineList) {
                $item = New-Object System.Windows.Controls.ComboBoxItem
                $item.Content = $m.MachineName
                $cmb.Items.Add($item) | Out-Null
            }
            $defaultIdx = [math]::Min($n - 1, $cmb.Items.Count - 1)
            if ($cmb.Items.Count -gt 0) { $cmb.SelectedIndex = $defaultIdx }
        }
        & $capUpdateDOC

        # Show Configuration Options panel and sync DOC row visibility
        $capControls['PanelConfigOptions'].Visibility = 'Visible'
        $docCnt = if ($capControls['CmbDOCCount'].SelectedItem) { [int]$capControls['CmbDOCCount'].SelectedItem.Content } else { 3 }
        $capControls['GridDOCRow2'].Visibility = if ($docCnt -ge 2) { 'Visible' } else { 'Collapsed' }
        $capControls['GridDOCRow3'].Visibility = if ($docCnt -ge 3) { 'Visible' } else { 'Collapsed' }
        $capControls['BtnConfigure'].IsEnabled = $true
        $capControls['MainScroller'].ScrollToEnd()

        # Store fetched machines for use during configuration
        $Global:FetchedMachines = $machineList
    }.GetNewClosure())
    $fetchTimer.Start()
})

# ---- Configure button -------------------------------------------------------

$controls['BtnConfigure'].Add_Click({
    $siteCode = if ($controls['CmbSiteCode'].SelectedItem) { $controls['CmbSiteCode'].SelectedItem.Content } else { '' }
    if (-not $siteCode) {
        [System.Windows.MessageBox]::Show("Select a Site.", "Missing", "OK", "Warning") | Out-Null; return
    }
    if (-not $Global:FetchedMachines -or $Global:FetchedMachines.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Fetch machines from Site DB first.", "Missing", "OK", "Warning") | Out-Null; return
    }

    $installerUser = $controls['TxtUsername'].Text.Trim()
    $installerPwd  = $controls['PwdUserAccount'].Password
    if (-not $installerUser -or -not $installerPwd) {
        [System.Windows.MessageBox]::Show("Enter your domain username and password.", "Credentials Required", "OK", "Warning") | Out-Null; return
    }
    if (-not (Test-InstallerCredential -DomainUser $installerUser -Password $installerPwd)) {
        [System.Windows.MessageBox]::Show("Authentication failed for '$installerUser'.", "Authentication Failed", "OK", "Error") | Out-Null; return
    }
    if (-not $controls['PwdAPCUser'].Password -or -not $controls['PwdMedtronicSU'].Password) {
        [System.Windows.MessageBox]::Show("Fill in apcuser (local) and MedtronicSU passwords.", "Passwords Required", "OK", "Warning") | Out-Null; return
    }
    $docItem  = if ($controls['CmbDOCCount'].SelectedItem) { $controls['CmbDOCCount'].SelectedItem.Content } else { '3' }
    $docCount = [int]$docItem
    $docMachineAssignments = @()
    for ($i = 1; $i -le $docCount; $i++) {
        $cmb = $controls["CmbDOCMachine$i"]
        $docMachineAssignments += if ($cmb -and $cmb.SelectedItem) { $cmb.SelectedItem.Content } else { '' }
    }

    $Script:AutoState = Get-CurrentState
    $Script:AutoState['CNCMachines']           = $Global:FetchedMachines
    $Script:AutoState['DOCMachineAssignments'] = $docMachineAssignments

    $apcPwd = New-Object System.Security.SecureString
    foreach ($c in $controls['PwdAPCUser'].Password.ToCharArray()) { $apcPwd.AppendChar($c) }
    $suPwd  = New-Object System.Security.SecureString
    foreach ($c in $controls['PwdMedtronicSU'].Password.ToCharArray()) { $suPwd.AppendChar($c) }
    $sdbPwd = New-Object System.Security.SecureString
    foreach ($c in $controls['PwdSiteDB'].Password.ToCharArray()) { $sdbPwd.AppendChar($c) }

    $Script:AutoState['APCUserPassword']     = $apcPwd
    $Script:AutoState['MedtronicSUPassword'] = $suPwd
    $Script:AutoState['SiteDBPassword']      = $sdbPwd
    Save-State -State $Script:AutoState

    $startStep = if ($controls['CmbStartStep'].SelectedItem) { [int]$controls['CmbStartStep'].SelectedItem.Content } else { 1 }
    $Script:AutoIndex = $startStep - 1
    1..($startStep - 1) | ForEach-Object { Set-StepState -Index $_ -State 'Skipped' }
    ($startStep)..13   | ForEach-Object { Set-StepState -Index $_ -State 'Pending' }
    $controls['LogAll'].Text                      = ''
    $controls['BarOverall'].Value                 = 0
    $controls['TxtProgressLabel'].Text            = "0 / 13"
    $controls['PanelProgress'].Visibility         = 'Visible'
    $controls['PanelPostConfig'].Visibility       = 'Collapsed'
    $controls['BtnConfigure'].IsEnabled           = $false
    $controls['MainScroller'].ScrollToEnd()

    Run-NextAutoModule
})

# ---- Re-run buttons ---------------------------------------------------------

1..13 | ForEach-Object {
    $idx = $_
    $controls["BtnRerun$idx"].Add_Click({
        $mod = $Script:StepDefs | Where-Object { $_.Index -eq $idx }
        Set-StepState -Index $idx -State 'Running'
        Start-ModuleInWindow `
            -ModuleFile   $mod.File `
            -FunctionName $mod.Fn `
            -State        (Get-CurrentState) `
            -LogBox       $controls['LogAll'] `
            -OnDone       {
                param([bool]$ok)
                Set-StepState -Index $idx -State $(if ($ok) { 'Done' } else { 'Failed' })
            }
    }.GetNewClosure())
}

# ---- Post-config: Verification ----------------------------------------------

$controls['BtnRunVerification'].Add_Click({
    $controls['LogVerification'].Visibility       = 'Visible'
    $controls['TxtVerificationStatus'].Text       = 'Running...'
    $controls['TxtVerificationStatus'].Foreground = '#4361EE'
    Start-ModuleInWindow `
        -ModuleFile   '13-Verification.ps1' `
        -FunctionName 'Invoke-ConfigVerification' `
        -State        (Get-CurrentState) `
        -LogBox       $controls['LogVerification'] `
        -OnDone       {
            param([bool]$ok)
            $controls['TxtVerificationStatus'].Text       = if ($ok) { 'Complete' } else { 'Errors - see log' }
            $controls['TxtVerificationStatus'].Foreground = if ($ok) { '#166534'  } else { '#EF4444' }
        }
})

# ---- Post-config: Report ----------------------------------------------------

$controls['BtnGenerateReport'].Add_Click({
    $reviewer = $controls['TxtReviewerName'].Text.Trim()
    $revRole  = $controls['TxtReviewerRole'].Text.Trim()
    if (-not $reviewer -or -not $revRole) {
        [System.Windows.MessageBox]::Show("Enter Reviewer Name and Role.", "Missing", "OK", "Warning") | Out-Null; return
    }
    $decision = ($controls['CmbDecision'].SelectedItem.Content -split ' - ')[0].Trim()

    if (Test-Path $Script:StateFile) {
        $raw = Get-Content $Script:StateFile -Raw | ConvertFrom-Json
        $sh  = @{}; $raw.PSObject.Properties | ForEach-Object { $sh[$_.Name] = $_.Value }
        $sh['SignOff'] = @{ ReviewerName = $reviewer; ReviewerRole = $revRole; Decision = $decision; Timestamp = (Get-Date -Format 'o') }
        $sh | ConvertTo-Json -Depth 10 | Set-Content $Script:StateFile -Encoding UTF8
    }

    $controls['LogReport'].Visibility       = 'Visible'
    $controls['TxtReportStatus'].Text       = 'Generating...'
    $controls['TxtReportStatus'].Foreground = '#4361EE'
    Start-ModuleInWindow `
        -ModuleFile   '13-Verification.ps1' `
        -FunctionName 'Invoke-GenerateReport' `
        -State        (Get-CurrentState) `
        -LogBox       $controls['LogReport'] `
        -OnDone       {
            $controls['BtnOpenReport'].Visibility  = 'Visible'
            $controls['TxtReportPath'].Text        = 'Report saved to: C:\APC_Config\Reports\'
            $controls['TxtReportPath'].Visibility  = 'Visible'
            $controls['TxtReportStatus'].Text      = 'Done'
            $controls['TxtReportStatus'].Foreground = '#166534'
        }
})

$controls['BtnOpenReport'].Add_Click({
    $latest = Get-ChildItem 'C:\APC_Config\Reports\' -Filter '*.html' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Start-Process $latest.FullName }
})

$window.ShowDialog() | Out-Null
