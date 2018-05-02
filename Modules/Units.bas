Attribute VB_Name = "Units"
'***************************************************************************
'Unit Conversion Functions
'Copyright 2014-2018 by Tanner Helland
'Created: 10/February/14
'Last updated: 30/December/14
'Last update: harden code against potential divide-by-zero errors
'
'Many of these functions are older than the create date above, but I did not organize them into a consistent module
' until February '14.  This module is now used to store all the random bits of unit conversion math required by the
' program.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit


'Units of measurement, as used by PD (particularly the resize dialogs)
Public Enum PD_MeasurementUnit
    mu_Percent = 0
    mu_Pixels = 1
    mu_Inches = 2
    mu_Centimeters = 3
    mu_Millimeters = 4
End Enum

#If False Then
    Private Const mu_Percent = 0, mu_Pixels = 1, mu_Inches = 2, mu_Centimeters = 3, mu_Millimeters = 4
#End If

Public Enum PD_ResolutionUnit
    ru_PPI = 0
    ru_PPCM = 1
End Enum

#If False Then
    Private Const ru_PPI = 0, ru_PPCM = 1
#End If

'Given a measurement in pixels, convert it to some other unit of measurement.  Note that at least two parameters are required:
' the unit of measurement to use, and a source measurement (in pixels, obviously).  Depending on the conversion, one of two
' optional parameters may also be necessary: a pixel resolution, expressed as PPI (needed for absolute measurements like inches
' or cm), and for percentage, an ORIGINAL value, in pixels, must be supplied.
Public Function ConvertPixelToOtherUnit(ByVal curUnit As PD_MeasurementUnit, ByVal srcPixelValue As Double, Optional ByVal srcPixelResolution As Double, Optional ByVal initPixelValue As Double) As Double

    Select Case curUnit
    
        Case mu_Percent
            If (initPixelValue <> 0) Then ConvertPixelToOtherUnit = (srcPixelValue / initPixelValue) * 100#
            
        Case mu_Pixels
            ConvertPixelToOtherUnit = srcPixelValue
            
        Case mu_Inches
            If (srcPixelResolution <> 0) Then ConvertPixelToOtherUnit = srcPixelValue / srcPixelResolution
        
        Case mu_Centimeters
            If (srcPixelResolution <> 0) Then ConvertPixelToOtherUnit = GetCMFromInches(srcPixelValue / srcPixelResolution)
            
        Case mu_Millimeters
            If (srcPixelResolution <> 0) Then ConvertPixelToOtherUnit = GetCMFromInches(srcPixelValue / srcPixelResolution) * 10#
    
    End Select

End Function

'Given a measurement in something other than pixels, convert it to pixels.  Note that at least two parameters are required:
' the unit of measurement that defines the source value, and the source value itself.  Depending on the conversion, one of two
' optional parameters may also be necessary: a resolution, expressed as PPI (needed to convert from absolute measurements like
' inches or cm), and for percentage, an ORIGINAL value, in pixels, must be supplied.  Note that in the unique case of percent,
' the "srcUnitValue" will be the percent used for conversion (as a percent, e.g. 100.0 for 100%).
Public Function ConvertOtherUnitToPixels(ByVal curUnit As PD_MeasurementUnit, ByVal srcUnitValue As Double, Optional ByVal srcUnitResolution As Double, Optional ByVal initPixelValue As Double) As Double

    'The translation function used depends on the currently selected unit
    Select Case curUnit
    
        Case mu_Percent
            ConvertOtherUnitToPixels = CDbl(srcUnitValue / 100#) * initPixelValue
        
        Case mu_Pixels
            ConvertOtherUnitToPixels = srcUnitValue
        
        Case mu_Inches
            ConvertOtherUnitToPixels = Int(srcUnitValue * srcUnitResolution + 0.5)
        
        Case mu_Centimeters
            ConvertOtherUnitToPixels = Int(GetInchesFromCM(srcUnitValue) * srcUnitResolution + 0.5)
            
        Case mu_Millimeters
            ConvertOtherUnitToPixels = Int(GetInchesFromCM(srcUnitValue / 10#) * srcUnitResolution + 0.5)
        
    End Select
    
End Function

'Basic metric/imperial conversions for length
Public Function GetInchesFromCM(ByVal srcCM As Double) As Double
    GetInchesFromCM = srcCM * 0.393700787
End Function

Public Function GetCMFromInches(ByVal srcInches As Double) As Double
    GetCMFromInches = srcInches * 2.54
End Function
