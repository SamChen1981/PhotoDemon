Attribute VB_Name = "Palettes"
'***************************************************************************
'PhotoDemon's Master Palette Interface
'Copyright 2017-2018 by Tanner Helland
'Created: 12/January/17
'Last updated: 31/January/18
'Last update: finish work on KD-tree palette matcher, which is both faster and more accurate than GDI matching
'
'This module contains a bunch of helper algorithms for generating optimal palettes from arbitrary source images,
' and also applying arbitrary palettes to images.  In the future, I expect it to include a lot more interesting
' palette code, including swatch imports from a variety of external sources.
'
'In the meantime, please note that this module has quite a few dependencies.  In particular, it performs
' no quantization (and relatively little palette-matching) on its own.  This is primarily delegated to helper classes.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'Do *not* change the order of this enum unless you also change the order of common dialog filters in the
' Load/Save palette functions.  Those indices need to match 1:1 to this enum.
Public Enum PD_PaletteFormat
    pdpf_AdobeColorSwatch = 0
    pdpf_AdobeColorTable = 1
    pdpf_AdobeSwatchExchange = 2
    pdpf_GIMP = 3
    pdpf_PSP = 4
    pdpf_PaintDotNet = 5
End Enum

#If False Then
    Private Const pdpf_AdobeColorSwatch = 0, pdpf_AdobeColorTable = 1, pdpf_AdobeSwatchExchange = 2, pdpf_GIMP = 3, pdpf_PSP = 4, pdpf_PaintDotNet = 5
#End If

'Used for more accurate color distance comparisons (using human eye sensitivity as a rough guide, while staying in
' the sRGB space for performance reasons)
Private Const CUSTOM_WEIGHT_RED As Single = 0.299
Private Const CUSTOM_WEIGHT_GREEN As Single = 0.587
Private Const CUSTOM_WEIGHT_BLUE As Single = 0.114

'WAPI provides palette matching functions that run quite a bit faster than an equivalent VB function; we use this
' if "perfect" palette matching is desired (where an exhaustive search is applied against each pixel in the image,
' and each entry in a palette).
Private Type GDI_PALETTEENTRY
    peR     As Byte
    peG     As Byte
    peB     As Byte
    peFlags As Byte
End Type

Private Type GDI_LOGPALETTE256
    palVersion       As Integer
    palNumEntries    As Integer
    palEntry(0 To 255) As GDI_PALETTEENTRY
End Type

Private Declare Function CreatePalette Lib "gdi32" (ByVal lpLogPalette As Long) As Long
Private Declare Function DeleteObject Lib "gdi32" (ByVal hObject As Long) As Long
Private Declare Function GetNearestPaletteIndex Lib "gdi32" (ByVal hPalette As Long, ByVal crColor As Long) As Long
Private Declare Sub FillMemory Lib "kernel32" Alias "RtlFillMemory" (ByVal dstPointer As Long, ByVal Length As Long, ByVal Fill As Byte)

'When interacting with a pdPalette class instance, additional options are available.  In particular,
' pdPalette-based palettes support the following per-color features:
' - RGBA color descriptors (including alpha, although in many places PD does *not* guarantee that
'   alpha values for a given palette entry will be respected during matching).
' - Color name.  Some palette formats provide per-color names; some do not.  This value may be null.
Public Type PDPaletteEntry
    ColorValue As RGBQuad
    ColorName As String
End Type

Public Type PDPaletteCache
    ColorValue As RGBQuad
    OrigIndex As Long
End Type

'Given a source image, an (empty) destination palette array, and a color count, return an optimized palette using
' the source image as the reference.  A modified median-cut system is used, and it achieves a very nice
' combination of performance, low memory usage, and high-quality output.
'
'Because palette generation is a time-consuming task, the source DIB should generally be shrunk to a much smaller
' version of itself.  I built a function specifically for this: DIBs.ResizeDIBByPixelCount().  That function
' resizes an image to a target pixel count, and I wouldn't recommend a net size any larger than ~50,000 pixels.
Public Function GetOptimizedPalette(ByRef srcDIB As pdDIB, ByRef dstPalette() As RGBQuad, Optional ByVal numOfColors As Long = 256, Optional ByVal quantMode As PD_QuantizeMode = pdqs_Variance) As Boolean
    
    'Do not request less than two colors in the final palette!
    If (numOfColors < 2) Then numOfColors = 2
    
    Dim srcPixels() As Byte, tmpSA As SafeArray2D
    srcDIB.WrapArrayAroundDIB srcPixels, tmpSA
    
    Dim pxSize As Long
    pxSize = srcDIB.GetDIBColorDepth \ 8
    
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = 0
    initY = 0
    finalX = srcDIB.GetDIBStride - 1
    finalY = srcDIB.GetDIBHeight - 1
    
    'Add all pixels from the source image to a base color stack
    Dim pxStack() As pdMedianCut
    ReDim pxStack(0 To numOfColors - 1) As pdMedianCut
    Set pxStack(0) = New pdMedianCut
    
    'Note that PD actually supports quite a few different quantization methods.  At present, we use a technique
    ' that's a good compromise between performance and quality.
    pxStack(0).SetQuantizeMode quantMode
    
    For y = 0 To finalY
    For x = 0 To finalX Step pxSize
        pxStack(0).AddColor_RGB srcPixels(x + 2, y), srcPixels(x + 1, y), srcPixels(x, y)
    Next x
    Next y
    
    srcDIB.UnwrapArrayFromDIB srcPixels
    
    'Next, make sure there are more than [numOfColors] colors in the image (otherwise, our work is already done!)
    If (pxStack(0).GetNumOfColors > numOfColors) Then
        
        Dim stackCount As Long
        stackCount = 1
        
        Dim maxVariance As Single, mvIndex As Long
        Dim i As Long
        
        Dim rVariance As Single, gVariance As Single, bVariance As Single, netVariance As Single
        
        'With the initial stack constructed, we can now start partitioning it into smaller stacks based on variance
        Do
        
            'Reset maximum variance (because we need to calculate it anew)
            maxVariance = 0!
            
            'Find the largest total variance in the current stack collection
            For i = 0 To stackCount - 1
            
                pxStack(i).GetVariance rVariance, gVariance, bVariance
                
                netVariance = rVariance + gVariance + bVariance
                If (netVariance > maxVariance) Then
                    mvIndex = i
                    maxVariance = netVariance
                End If
                
            Next i
            
            'Ask the stack with the largest net variance to split itself in half.  (Note that the stack object
            ' itself decides which axis is most appropriate for splitting; typically this is the axis - channel -
            ' with the largest variance.)
            'Debug.Print "Largest variance was " & maxVariance & ", found in stack #" & mvIndex & " (total stack count is " & stackCount & ")"
            If (maxVariance > 0) Then
                pxStack(mvIndex).Split pxStack(stackCount)
                stackCount = stackCount + 1
            
            'All current stacks only contain a single color, meaning this image contains fewer unique colors
            ' than the target number of colors the user requested.  That's okay!  Exit now, and use the colors
            ' we've discovered as the optimal palette.
            Else
                numOfColors = stackCount
                Exit Do
            End If
        
        'Continue splitting stacks until we arrive at the desired number of colors.  (Each stack represents
        ' one color in the final palette.)
        Loop While (stackCount < numOfColors)
        
        'We now have [numOfColors] unique color stacks.  Each of these represents a set of similar colors.
        ' Generate a final palette by requesting the weighted average of each stack.  (As an alternate solution,
        ' you could also request the most "populous" color; this would preserve precise tones from the image,
        ' but rarely-appearing colors would never influence the final output.  Trade-offs!
        Dim newR As Long, newG As Long, newB As Long
        ReDim dstPalette(0 To numOfColors - 1) As RGBQuad
        For i = 0 To numOfColors - 1
            pxStack(i).GetAverageColor newR, newG, newB
            dstPalette(i).Red = newR
            dstPalette(i).Green = newG
            dstPalette(i).Blue = newB
        Next i
        
        GetOptimizedPalette = True
        
    'If there are less than [numOfColors] unique colors in the image, simply copy the existing stack into a palette
    Else
        pxStack(0).CopyStackToRGBQuad dstPalette
        GetOptimizedPalette = True
    End If
    
End Function

'Given a palette, make sure black and white exist.  This function scans the palette and replaces the darkest
' entry with black, and the brightest entry with white.  (We use this approach so that we can accept palettes
' from any source, even ones that have already contain 256+ entries.)  No changes are made to palettes that
' already contain black and white.
Public Function EnsureBlackAndWhiteInPalette(ByRef srcPalette() As RGBQuad, Optional ByRef srcDIB As pdDIB = Nothing) As Boolean
    
    Dim minLuminance As Long, minLuminanceIndex As Long
    Dim maxLuminance As Long, maxLuminanceIndex As Long
    
    Dim pBoundL As Long, pBoundU As Long
    pBoundL = LBound(srcPalette)
    pBoundU = UBound(srcPalette)
    
    If (pBoundL <> pBoundU) Then
    
        With srcPalette(pBoundL)
            minLuminance = Colors.GetHQLuminance(.Red, .Green, .Blue)
            minLuminanceIndex = pBoundL
            maxLuminance = Colors.GetHQLuminance(.Red, .Green, .Blue)
            maxLuminanceIndex = pBoundL
        End With
        
        Dim testLuminance As Long
        
        Dim i As Long
        For i = pBoundL + 1 To pBoundU
        
            With srcPalette(i)
                testLuminance = Colors.GetHQLuminance(.Red, .Green, .Blue)
            End With
            
            If (testLuminance > maxLuminance) Then
                maxLuminance = testLuminance
                maxLuminanceIndex = i
            ElseIf (testLuminance < minLuminance) Then
                minLuminance = testLuminance
                minLuminanceIndex = i
            End If
            
        Next i
        
        Dim preserveWhite As Boolean, preserveBlack As Boolean
        preserveWhite = True
        preserveBlack = True
        
        'If the caller passed us an image, see if the image contains black and/or white.  If it does *not*,
        ' we won't worry about preserving that particular color
        If (Not srcDIB Is Nothing) Then
        
            Dim srcPixels() As Byte, tmpSA As SafeArray2D
            srcDIB.WrapArrayAroundDIB srcPixels, tmpSA
            
            Dim pxSize As Long
            pxSize = srcDIB.GetDIBColorDepth \ 8
            
            Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
            initX = 0
            initY = 0
            finalX = srcDIB.GetDIBStride - 1
            finalY = srcDIB.GetDIBHeight - 1
            
            Dim r As Long, g As Long, b As Long
            Dim blackFound As Boolean, whiteFound As Boolean
            
            For y = 0 To finalY
            For x = 0 To finalX Step pxSize
                b = srcPixels(x, y)
                g = srcPixels(x + 1, y)
                r = srcPixels(x + 2, y)
                
                If (Not blackFound) Then
                    If (r = 0) And (g = 0) And (b = 0) Then blackFound = True
                End If
                
                If (Not whiteFound) Then
                    If (r = 255) And (g = 255) And (b = 255) Then whiteFound = True
                End If
                
                If (blackFound And whiteFound) Then Exit For
            Next x
                If (blackFound And whiteFound) Then Exit For
            Next y
            
            srcDIB.UnwrapArrayFromDIB srcPixels
            
            preserveBlack = blackFound
            preserveWhite = whiteFound
    
        End If
        
        If preserveBlack Then
            With srcPalette(minLuminanceIndex)
                .Red = 0
                .Green = 0
                .Blue = 0
            End With
        End If
        
        If preserveWhite Then
            With srcPalette(maxLuminanceIndex)
                .Red = 255
                .Green = 255
                .Blue = 255
            End With
        End If
        
        EnsureBlackAndWhiteInPalette = True
        
    Else
        EnsureBlackAndWhiteInPalette = False
    End If

End Function

'Given an arbitrary source palette, apply said palette to the target image.  Dithering is *not* used.
' Colors are matched exhaustively, meaning this function slows significantly as palette size increases.
Public Function ApplyPaletteToImage_Naive(ByRef dstDIB As pdDIB, ByRef srcPalette() As RGBQuad) As Boolean

    Dim srcPixels() As Byte, tmpSA As SafeArray2D
    dstDIB.WrapArrayAroundDIB srcPixels, tmpSA
    
    Dim pxSize As Long
    pxSize = dstDIB.GetDIBColorDepth \ 8
    
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = 0
    initY = 0
    finalX = dstDIB.GetDIBStride - 1
    finalY = dstDIB.GetDIBHeight - 1
    
    'We'll use basic RLE acceleration to try and skip palette matching for long runs of contiguous colors
    Dim lastColor As Long: lastColor = -1
    Dim lastPaletteColor As Long
    Dim r As Long, g As Long, b As Long
    Dim i As Long
    Dim minDistance As Single, calcDistance As Single, minIndex As Long
    Dim rDist As Long, gDist As Long, bDist As Long
    Dim numOfColors As Long
    numOfColors = UBound(srcPalette)
    
    For y = 0 To finalY
    For x = 0 To finalX Step pxSize
        b = srcPixels(x, y)
        g = srcPixels(x + 1, y)
        r = srcPixels(x + 2, y)
        
        'If this color matches the last color we tested, reuse our previous palette match
        If (RGB(r, g, b) <> lastColor) Then
            
            'Find the closest color in the current list, using basic Euclidean distance to compare colors
            minIndex = 0
            minDistance = 9.999999E+16
            
            For i = 0 To numOfColors
                With srcPalette(i)
                    rDist = r - .Red
                    gDist = g - .Green
                    bDist = b - .Blue
                End With
                calcDistance = (rDist * rDist) * CUSTOM_WEIGHT_RED + (gDist * gDist) * CUSTOM_WEIGHT_GREEN + (bDist * bDist) * CUSTOM_WEIGHT_BLUE
                If (calcDistance < minDistance) Then
                    minDistance = calcDistance
                    minIndex = i
                End If
            Next i
            
            lastColor = RGB(r, g, b)
            lastPaletteColor = minIndex
            
        Else
            minIndex = lastPaletteColor
        End If
        
        'Apply this color to the target image
        srcPixels(x, y) = srcPalette(minIndex).Blue
        srcPixels(x + 1, y) = srcPalette(minIndex).Green
        srcPixels(x + 2, y) = srcPalette(minIndex).Red
        
    Next x
    Next y
    
    dstDIB.UnwrapArrayFromDIB srcPixels
    
    ApplyPaletteToImage_Naive = True
    
End Function

'Given a source palette (ideally created by GetOptimizedPalette(), above), apply said palette to the target image.
' Dithering is *not* used.  Colors are matched using an octree-search strategy (where the palette is pre-loaded
' into an octree, and colors are matched via that tree).  If the palette is known to be small (e.g. 32 colors or less),
' you'd be better off just calling the normal ApplyPaletteToImage function, as this function won't provide much of a
' performance gain.
Public Function ApplyPaletteToImage_Octree(ByRef dstDIB As pdDIB, ByRef srcPalette() As RGBQuad) As Boolean

    Dim srcPixels() As Byte, tmpSA As SafeArray2D
    dstDIB.WrapArrayAroundDIB srcPixels, tmpSA
    
    Dim pxSize As Long
    pxSize = dstDIB.GetDIBColorDepth \ 8
    
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = 0
    initY = 0
    finalX = dstDIB.GetDIBStride - 1
    finalY = dstDIB.GetDIBHeight - 1
    
    'As with normal palette matching, we'll use basic RLE acceleration to try and skip palette
    ' searching for contiguous matching colors.
    Dim lastColor As Long: lastColor = -1
    Dim minIndex As Long, lastPaletteColor As Long
    Dim r As Long, g As Long, b As Long
    
    Dim tmpQuad As RGBQuad
        
    'Build the initial tree
    Dim cOctree As pdColorSearch
    Set cOctree = New pdColorSearch
    cOctree.CreateColorTree srcPalette
    
    'Octrees tend to make colors darker, because they match colors bit-by-bit, meaning dark colors are
    ' preferentially matched over light ones.  (e.g. &h0111 would match to &h0000 rather than &h1000,
    ' because bits are matched in most-significant to least-significant order).
    
    'To reduce the impact this has on the final image, I've considered artifically brightening colors
    ' before matching them.  The problem is that we really only need to do this around power-of-two
    ' values, and mathematically, I'm not sure how to do this most efficiently (e.g. without just making
    ' colors biased against brighter matches instead).
    
    'As such, I've marked this as "TODO" for now.
    'Dim octHelper() As Byte
    'ReDim octHelper(0 To 255) As Byte
    'For x = 0 To 255
    '    r = x + 10
    '    If (r > 255) Then octHelper(x) = 255 Else octHelper(x) = r
    'Next x
    '(Obviously, for this to work, you'd need to updated the tmpQuad assignments in the inner loop, below.)
    
    'Start matching pixels
    For y = 0 To finalY
    For x = 0 To finalX Step pxSize
    
        b = srcPixels(x, y)
        g = srcPixels(x + 1, y)
        r = srcPixels(x + 2, y)
        
        'If this pixel matches the last pixel we tested, reuse our previous match results
        If (RGB(r, g, b) <> lastColor) Then
            
            tmpQuad.Red = r
            tmpQuad.Green = g
            tmpQuad.Blue = b
            
            'Ask the octree to find the best match
            minIndex = cOctree.GetNearestPaletteIndex(tmpQuad)
            
            lastColor = RGB(r, g, b)
            lastPaletteColor = minIndex
            
        Else
            minIndex = lastPaletteColor
        End If
        
        'Apply the closest discovered color to this pixel.
        srcPixels(x, y) = srcPalette(minIndex).Blue
        srcPixels(x + 1, y) = srcPalette(minIndex).Green
        srcPixels(x + 2, y) = srcPalette(minIndex).Red
        
    Next x
    Next y
    
    dstDIB.UnwrapArrayFromDIB srcPixels
    
    ApplyPaletteToImage_Octree = True
    
End Function

'Given an arbitrary palette (including palettes > 256 colors - they work just fine!), apply said palette to the
' target image.  Dithering is *not* used.  Colors are matched using a KD-tree (where the palette is pre-loaded into
' a tree, and colors are matched via that tree).
Public Function ApplyPaletteToImage_KDTree(ByRef dstDIB As pdDIB, ByRef srcPalette() As RGBQuad, Optional ByVal suppressMessages As Boolean = False, Optional ByVal modifyProgBarMax As Long = -1, Optional ByVal modifyProgBarOffset As Long = 0) As Boolean

    Dim srcPixels() As Byte, tmpSA As SafeArray1D
    
    Dim pxSize As Long
    pxSize = dstDIB.GetDIBColorDepth \ 8
    
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = 0
    initY = 0
    finalX = dstDIB.GetDIBStride - 1
    finalY = dstDIB.GetDIBHeight - 1
    
    'To keep processing quick, only update the progress bar when absolutely necessary.  This function calculates a
    ' refresh interval based on the size of the area to be processed.
    Dim progBarCheck As Long
    If (Not suppressMessages) Then
        If (modifyProgBarMax = -1) Then SetProgBarMax finalY Else SetProgBarMax modifyProgBarMax
        progBarCheck = ProgressBars.FindBestProgBarValue()
    End If
    
    'As with normal palette matching, we'll use basic RLE acceleration to try and skip palette
    ' searching for contiguous matching colors.
    Dim lastColor As Long: lastColor = -1
    Dim r As Long, g As Long, b As Long
    
    Dim tmpQuad As RGBQuad, newQuad As RGBQuad, lastQuad As RGBQuad
    
    'Build the initial tree
    Dim kdTree As pdKDTree
    Set kdTree = New pdKDTree
    kdTree.BuildTree srcPalette, UBound(srcPalette) + 1
    
    'Start matching pixels
    For y = 0 To finalY
        dstDIB.WrapArrayAroundScanline srcPixels, tmpSA, y
    For x = 0 To finalX Step pxSize
    
        b = srcPixels(x)
        g = srcPixels(x + 1)
        r = srcPixels(x + 2)
        
        'If this pixel matches the last pixel we tested, reuse our previous match results
        If (RGB(r, g, b) <> lastColor) Then
            
            tmpQuad.Red = r
            tmpQuad.Green = g
            tmpQuad.Blue = b
            
            'Ask the tree for its best match
            newQuad = kdTree.GetNearestColor(tmpQuad)
            
            lastColor = RGB(r, g, b)
            lastQuad = newQuad
            
        Else
            newQuad = lastQuad
        End If
        
        'Apply the closest discovered color to this pixel.
        srcPixels(x) = newQuad.Blue
        srcPixels(x + 1) = newQuad.Green
        srcPixels(x + 2) = newQuad.Red
        
    Next x
        If (Not suppressMessages) Then
            If (y And progBarCheck) = 0 Then
                If Interface.UserPressedESC() Then Exit For
                SetProgBarVal y + modifyProgBarOffset
            End If
        End If
    Next y
    
    dstDIB.UnwrapArrayFromDIB srcPixels
    
    ApplyPaletteToImage_KDTree = True
    
End Function

'Given a source palette (ideally created by GetOptimizedPalette(), above), apply said palette to the target image.
' Dithering is *not* used.  Colors are matched using Windows APIs.
Public Function ApplyPaletteToImage_SysAPI(ByRef dstDIB As pdDIB, ByRef srcPalette() As RGBQuad) As Boolean

    Dim srcPixels() As Byte, tmpSA As SafeArray2D
    dstDIB.WrapArrayAroundDIB srcPixels, tmpSA
    
    Dim pxSize As Long
    pxSize = dstDIB.GetDIBColorDepth \ 8
    
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = 0
    initY = 0
    finalX = dstDIB.GetDIBStride - 1
    finalY = dstDIB.GetDIBHeight - 1
    
    'As with normal palette matching, we'll use basic RLE acceleration to try and skip palette
    ' searching for contiguous matching colors.
    Dim lastColor As Long: lastColor = -1
    Dim minIndex As Long, lastPaletteColor As Long
    Dim r As Long, g As Long, b As Long
    
    Dim tmpPalette As GDI_LOGPALETTE256
    tmpPalette.palNumEntries = UBound(srcPalette) + 1
    tmpPalette.palVersion = &H300
    Dim i As Long
    For i = 0 To UBound(srcPalette)
        tmpPalette.palEntry(i).peR = srcPalette(i).Red
        tmpPalette.palEntry(i).peG = srcPalette(i).Green
        tmpPalette.palEntry(i).peB = srcPalette(i).Blue
    Next i
    
    Dim hPal As Long
    hPal = CreatePalette(VarPtr(tmpPalette))
    
    'Start matching pixels
    For y = 0 To finalY
    For x = 0 To finalX Step pxSize
    
        b = srcPixels(x, y)
        g = srcPixels(x + 1, y)
        r = srcPixels(x + 2, y)
        
        'If this pixel matches the last pixel we tested, reuse our previous match results
        If (RGB(r, g, b) <> lastColor) Then
            
            'Ask the system to find the nearest color
            minIndex = GetNearestPaletteIndex(hPal, RGB(r, g, b))
            
            lastColor = RGB(r, g, b)
            lastPaletteColor = minIndex
            
        Else
            minIndex = lastPaletteColor
        End If
        
        'Apply the closest discovered color to this pixel.
        srcPixels(x, y) = srcPalette(minIndex).Blue
        srcPixels(x + 1, y) = srcPalette(minIndex).Green
        srcPixels(x + 2, y) = srcPalette(minIndex).Red
        
    Next x
    Next y
    
    dstDIB.UnwrapArrayFromDIB srcPixels
    
    If (hPal <> 0) Then DeleteObject hPal
    
    ApplyPaletteToImage_SysAPI = True
    
End Function

'Given an arbitrary source palette, apply said palette to the target image.
' Dithering *is* used.  Colors are matched using a KD-tree.
Public Function ApplyPaletteToImage_Dithered(ByRef dstDIB As pdDIB, ByRef srcPalette() As RGBQuad, Optional ByVal ditherMethod As PD_DITHER_METHOD = PDDM_FloydSteinberg, Optional ByVal ditherStrength As Single = 1!, Optional ByVal suppressMessages As Boolean = False, Optional ByVal modifyProgBarMax As Long = -1, Optional ByVal modifyProgBarOffset As Long = 0) As Boolean

    Dim srcPixels() As Byte, tmpSA As SafeArray2D
    dstDIB.WrapArrayAroundDIB srcPixels, tmpSA
    
    Dim srcPixels1D() As Byte, tmpSA1D As SafeArray1D, srcPtr As Long, srcStride As Long
    
    Dim pxSize As Long
    pxSize = dstDIB.GetDIBColorDepth \ 8
    
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = 0
    initY = 0
    finalX = dstDIB.GetDIBStride - 1
    finalY = dstDIB.GetDIBHeight - 1
    
    'To keep processing quick, only update the progress bar when absolutely necessary.  This function calculates a
    ' refresh interval based on the size of the area to be processed.
    Dim progBarCheck As Long
    If (Not suppressMessages) Then
        If (modifyProgBarMax = -1) Then SetProgBarMax finalY Else SetProgBarMax modifyProgBarMax
        progBarCheck = ProgressBars.FindBestProgBarValue()
    End If
    
    Dim r As Long, g As Long, b As Long, i As Long, j As Long
    Dim newQuad As RGBQuad, tmpQuad As RGBQuad
    
    'Validate dither strength
    If (ditherStrength < 0!) Then ditherStrength = 0!
    If (ditherStrength > 1!) Then ditherStrength = 1!
    
    'Build A KD-tree for fast palette matching
    Dim kdTree As pdKDTree
    Set kdTree = New pdKDTree
    kdTree.BuildTree srcPalette, UBound(srcPalette) + 1
    
    'Prep a dither table that matches the requested setting.  Note that ordered dithers are handled separately.
    Dim ditherTableI() As Byte, ditherDivisor As Single
    Dim xLeft As Long, xRight As Long, yDown As Long
    
    Dim orderedDitherInUse As Boolean
    orderedDitherInUse = (ditherMethod = PDDM_Ordered_Bayer4x4) Or (ditherMethod = PDDM_Ordered_Bayer8x8)
    
    If orderedDitherInUse Then
    
        'Ordered dithers are handled specially, because we don't need to track running errors (e.g. no dithering
        ' information is carried to neighboring pixels).  Instead, we simply use the dither tables to adjust our
        ' threshold values on-the-fly.
        Dim ditherRows As Long, ditherColumns As Long
        
        'First, prepare a dithering table
        Palettes.GetDitherTable ditherMethod, ditherTableI, ditherDivisor, xLeft, xRight, yDown
        
        If (ditherMethod = PDDM_Ordered_Bayer4x4) Then
            ditherRows = 3
            ditherColumns = 3
        ElseIf (ditherMethod = PDDM_Ordered_Bayer8x8) Then
            ditherRows = 7
            ditherColumns = 7
        End If
        
        'By default, ordered dither trees use a scale of [0, 255].  This works great for thresholding
        ' against pure black/white, but for color data, it leads to extreme shifts.  Reduce the strength
        ' of the table before continuing.
        For x = 0 To ditherRows
        For y = 0 To ditherColumns
            ditherTableI(x, y) = ditherTableI(x, y) \ 2
        Next y
        Next x
        
        'Apply the finished dither table to the image
        Dim ditherAmt As Long
        
        dstDIB.WrapArrayAroundScanline srcPixels1D, tmpSA1D, 0
        srcPtr = tmpSA1D.pvData
        srcStride = tmpSA1D.cElements
        
        For y = 0 To finalY
            tmpSA1D.pvData = srcPtr + (srcStride * y)
        For x = 0 To finalX Step pxSize
        
            b = srcPixels1D(x)
            g = srcPixels1D(x + 1)
            r = srcPixels1D(x + 2)
            
            'Add dither to each component
            ditherAmt = Int(ditherTableI(Int(x \ 4) And ditherRows, y And ditherColumns)) - 63
            ditherAmt = ditherAmt * ditherStrength
            
            r = r + ditherAmt
            If (r > 255) Then
                r = 255
            ElseIf (r < 0) Then
                r = 0
            End If
            
            g = g + ditherAmt
            If (g > 255) Then
                g = 255
            ElseIf (g < 0) Then
                g = 0
            End If
            
            b = b + ditherAmt
            If (b > 255) Then
                b = 255
            ElseIf (b < 0) Then
                b = 0
            End If
            
            'Retrieve the best-match color
            tmpQuad.Blue = b
            tmpQuad.Green = g
            tmpQuad.Red = r
            newQuad = kdTree.GetNearestColor(tmpQuad)
            
            srcPixels1D(x) = newQuad.Blue
            srcPixels1D(x + 1) = newQuad.Green
            srcPixels1D(x + 2) = newQuad.Red
            
        Next x
            If (Not suppressMessages) Then
                If (y And progBarCheck) = 0 Then
                    If Interface.UserPressedESC() Then Exit For
                    SetProgBarVal y + modifyProgBarOffset
                End If
            End If
        Next y
        
        dstDIB.UnwrapArrayFromDIB srcPixels1D
    
    'All error-diffusion dither methods are handled similarly
    Else
        
        Dim rError As Long, gError As Long, bError As Long
        Dim errorMult As Single
        
        'Retrieve a hard-coded dithering table matching the requested dither type
        Palettes.GetDitherTable ditherMethod, ditherTableI, ditherDivisor, xLeft, xRight, yDown
        If (ditherDivisor <> 0!) Then ditherDivisor = 1! / ditherDivisor
        
        'Next, build an error tracking array.  Some diffusion methods require three rows worth of others;
        ' others require two.  Note that errors must be tracked separately for each color component.
        Dim xWidth As Long
        xWidth = workingDIB.GetDIBWidth - 1
        Dim rErrors() As Single, gErrors() As Single, bErrors() As Single
        ReDim rErrors(0 To xWidth, 0 To yDown) As Single
        ReDim gErrors(0 To xWidth, 0 To yDown) As Single
        ReDim bErrors(0 To xWidth, 0 To yDown) As Single
        
        Dim xNonStride As Long, xQuickInner As Long
        Dim newR As Long, newG As Long, newB As Long
        
        dstDIB.WrapArrayAroundScanline srcPixels1D, tmpSA1D, 0
        srcPtr = tmpSA1D.pvData
        srcStride = tmpSA1D.cElements
        
        'Start calculating pixels.
        For y = 0 To finalY
            tmpSA1D.pvData = srcPtr + (srcStride * y)
        For x = 0 To finalX Step pxSize
        
            b = srcPixels1D(x)
            g = srcPixels1D(x + 1)
            r = srcPixels1D(x + 2)
            
            'Add our running errors to the original colors
            xNonStride = x \ 4
            newR = r + rErrors(xNonStride, 0)
            newG = g + gErrors(xNonStride, 0)
            newB = b + bErrors(xNonStride, 0)
            
            If (newR > 255) Then
                newR = 255
            ElseIf (newR < 0) Then
                newR = 0
            End If
            
            If (newG > 255) Then
                newG = 255
            ElseIf (newG < 0) Then
                newG = 0
            End If
            
            If (newB > 255) Then
                newB = 255
            ElseIf (newB < 0) Then
                newB = 0
            End If
            
            'Find the best palette match
            tmpQuad.Blue = newB
            tmpQuad.Green = newG
            tmpQuad.Red = newR
            newQuad = kdTree.GetNearestColor(tmpQuad)
            
            With newQuad
            
                'Apply the closest discovered color to this pixel.
                srcPixels1D(x) = .Blue
                srcPixels1D(x + 1) = .Green
                srcPixels1D(x + 2) = .Red
            
                'Calculate new errors
                rError = newR - CLng(.Red)
                gError = newG - CLng(.Green)
                bError = newB - CLng(.Blue)
                
            End With
            
            'Reduce color bleed, if specified
            rError = rError * ditherStrength
            gError = gError * ditherStrength
            bError = bError * ditherStrength
            
            'Spread any remaining error to neighboring pixels, using the precalculated dither table as our guide
            For i = xLeft To xRight
            For j = 0 To yDown
                
                If (ditherTableI(i, j) <> 0) Then
                    
                    xQuickInner = xNonStride + i
                    
                    'Next, ignore target pixels that are off the image boundary
                    If (xQuickInner >= initX) Then
                        If (xQuickInner < xWidth) Then
                        
                            'If we've made it all the way here, we are able to actually spread the error to this location
                            errorMult = CSng(ditherTableI(i, j)) * ditherDivisor
                            rErrors(xQuickInner, j) = rErrors(xQuickInner, j) + (rError * errorMult)
                            gErrors(xQuickInner, j) = gErrors(xQuickInner, j) + (gError * errorMult)
                            bErrors(xQuickInner, j) = bErrors(xQuickInner, j) + (bError * errorMult)
                            
                        End If
                    End If
                    
                End If
                
            Next j
            Next i
            
        Next x
        
            'When moving to the next line, we need to "shift" all accumulated errors upward.
            ' (Basically, what was previously the "next" line, is now the "current" line.
            ' The last line of errors must also be zeroed-out.
            If (yDown > 0) Then
            
                CopyMemory ByVal VarPtr(rErrors(0, 0)), ByVal VarPtr(rErrors(0, 1)), (xWidth + 1) * 4
                CopyMemory ByVal VarPtr(gErrors(0, 0)), ByVal VarPtr(gErrors(0, 1)), (xWidth + 1) * 4
                CopyMemory ByVal VarPtr(bErrors(0, 0)), ByVal VarPtr(bErrors(0, 1)), (xWidth + 1) * 4
                
                If (yDown = 1) Then
                    FillMemory VarPtr(rErrors(0, 1)), (xWidth + 1) * 4, 0
                    FillMemory VarPtr(gErrors(0, 1)), (xWidth + 1) * 4, 0
                    FillMemory VarPtr(bErrors(0, 1)), (xWidth + 1) * 4, 0
                Else
                    CopyMemory ByVal VarPtr(rErrors(0, 1)), ByVal VarPtr(rErrors(0, 2)), (xWidth + 1) * 4
                    CopyMemory ByVal VarPtr(gErrors(0, 1)), ByVal VarPtr(gErrors(0, 2)), (xWidth + 1) * 4
                    CopyMemory ByVal VarPtr(bErrors(0, 1)), ByVal VarPtr(bErrors(0, 2)), (xWidth + 1) * 4
                    
                    FillMemory VarPtr(rErrors(0, 2)), (xWidth + 1) * 4, 0
                    FillMemory VarPtr(gErrors(0, 2)), (xWidth + 1) * 4, 0
                    FillMemory VarPtr(bErrors(0, 2)), (xWidth + 1) * 4, 0
                End If
                
            Else
                FillMemory VarPtr(rErrors(0, 0)), (xWidth + 1) * 4, 0
                FillMemory VarPtr(gErrors(0, 0)), (xWidth + 1) * 4, 0
                FillMemory VarPtr(bErrors(0, 0)), (xWidth + 1) * 4, 0
            End If
            
            'Update the progress bar, as necessary
            If (Not suppressMessages) Then
                If (y And progBarCheck) = 0 Then
                    If Interface.UserPressedESC() Then Exit For
                    SetProgBarVal y + modifyProgBarOffset
                End If
            End If
            
        Next y
        
        dstDIB.UnwrapArrayFromDIB srcPixels1D
    
    End If
    
    dstDIB.UnwrapArrayFromDIB srcPixels
    
    ApplyPaletteToImage_Dithered = True
    
End Function

'Populate a dithering table and relevant markers based on a specific dithering type.
' Returns: TRUE if successful; FALSE otherwise.  Note that some dither types (e.g. ordered dithers) do not
' use this function; they are handled specially.
Public Function GetDitherTable(ByVal ditherType As PD_DITHER_METHOD, ByRef dstDitherTable() As Byte, ByRef ditherDivisor As Single, ByRef xLeft As Long, ByRef xRight As Long, ByRef yDown As Long) As Boolean
    
    GetDitherTable = True
    
    Dim x As Long, y As Long
    
    Select Case ditherType
    
        Case PDDM_Ordered_Bayer4x4
        
            ReDim dstDitherTable(0 To 3, 0 To 3) As Byte
            
            dstDitherTable(0, 0) = 0
            dstDitherTable(0, 1) = 8
            dstDitherTable(0, 2) = 2
            dstDitherTable(0, 3) = 10
            
            dstDitherTable(1, 0) = 12
            dstDitherTable(1, 1) = 4
            dstDitherTable(1, 2) = 14
            dstDitherTable(1, 3) = 6
            
            dstDitherTable(2, 0) = 3
            dstDitherTable(2, 1) = 11
            dstDitherTable(2, 2) = 1
            dstDitherTable(2, 3) = 9
            
            dstDitherTable(3, 0) = 15
            dstDitherTable(3, 1) = 7
            dstDitherTable(3, 2) = 13
            dstDitherTable(3, 3) = 5
    
            'Scale the table to [0, 255] range
            For x = 0 To 3
            For y = 0 To 3
                dstDitherTable(x, y) = dstDitherTable(x, y) * 16
            Next y
            Next x
        
        Case PDDM_Ordered_Bayer8x8
            
            ReDim dstDitherTable(0 To 7, 0 To 7) As Byte
            
            dstDitherTable(0, 0) = 0
            dstDitherTable(0, 1) = 48
            dstDitherTable(0, 2) = 12
            dstDitherTable(0, 3) = 60
            dstDitherTable(0, 4) = 3
            dstDitherTable(0, 5) = 51
            dstDitherTable(0, 6) = 15
            dstDitherTable(0, 7) = 63
            
            dstDitherTable(1, 0) = 32
            dstDitherTable(1, 1) = 16
            dstDitherTable(1, 2) = 44
            dstDitherTable(1, 3) = 28
            dstDitherTable(1, 4) = 35
            dstDitherTable(1, 5) = 19
            dstDitherTable(1, 6) = 47
            dstDitherTable(1, 7) = 31
            
            dstDitherTable(2, 0) = 8
            dstDitherTable(2, 1) = 56
            dstDitherTable(2, 2) = 4
            dstDitherTable(2, 3) = 52
            dstDitherTable(2, 4) = 11
            dstDitherTable(2, 5) = 59
            dstDitherTable(2, 6) = 7
            dstDitherTable(2, 7) = 55
            
            dstDitherTable(3, 0) = 40
            dstDitherTable(3, 1) = 24
            dstDitherTable(3, 2) = 36
            dstDitherTable(3, 3) = 20
            dstDitherTable(3, 4) = 43
            dstDitherTable(3, 5) = 27
            dstDitherTable(3, 6) = 39
            dstDitherTable(3, 7) = 23
            
            dstDitherTable(4, 0) = 2
            dstDitherTable(4, 1) = 50
            dstDitherTable(4, 2) = 14
            dstDitherTable(4, 3) = 62
            dstDitherTable(4, 4) = 1
            dstDitherTable(4, 5) = 49
            dstDitherTable(4, 6) = 13
            dstDitherTable(4, 7) = 61
            
            dstDitherTable(5, 0) = 34
            dstDitherTable(5, 1) = 18
            dstDitherTable(5, 2) = 46
            dstDitherTable(5, 3) = 30
            dstDitherTable(5, 4) = 33
            dstDitherTable(5, 5) = 17
            dstDitherTable(5, 6) = 45
            dstDitherTable(5, 7) = 29
    
            dstDitherTable(6, 0) = 10
            dstDitherTable(6, 1) = 58
            dstDitherTable(6, 2) = 6
            dstDitherTable(6, 3) = 54
            dstDitherTable(6, 4) = 9
            dstDitherTable(6, 5) = 57
            dstDitherTable(6, 6) = 5
            dstDitherTable(6, 7) = 53
            
            dstDitherTable(7, 0) = 42
            dstDitherTable(7, 1) = 26
            dstDitherTable(7, 2) = 38
            dstDitherTable(7, 3) = 22
            dstDitherTable(7, 4) = 41
            dstDitherTable(7, 5) = 25
            dstDitherTable(7, 6) = 37
            dstDitherTable(7, 7) = 21
            
            'Scale the table to [0, 255] range
            For x = 0 To 7
            For y = 0 To 7
                dstDitherTable(x, y) = dstDitherTable(x, y) * 4
            Next y
            Next x
            
        Case PDDM_SingleNeighbor
        
            ReDim dstDitherTable(0 To 1, 0) As Byte
            
            dstDitherTable(1, 0) = 1
            ditherDivisor = 1
            
            xLeft = 0
            xRight = 1
            yDown = 0
            
        Case PDDM_FloydSteinberg
        
            ReDim dstDitherTable(-1 To 1, 0 To 1) As Byte
            
            dstDitherTable(1, 0) = 7
            dstDitherTable(-1, 1) = 3
            dstDitherTable(0, 1) = 5
            dstDitherTable(1, 1) = 1
            
            ditherDivisor = 16
        
            xLeft = -1
            xRight = 1
            yDown = 1
            
        Case PDDM_JarvisJudiceNinke
        
            ReDim dstDitherTable(-2 To 2, 0 To 2) As Byte
            
            dstDitherTable(1, 0) = 7
            dstDitherTable(2, 0) = 5
            dstDitherTable(-2, 1) = 3
            dstDitherTable(-1, 1) = 5
            dstDitherTable(0, 1) = 7
            dstDitherTable(1, 1) = 5
            dstDitherTable(2, 1) = 3
            dstDitherTable(-2, 2) = 1
            dstDitherTable(-1, 2) = 3
            dstDitherTable(0, 2) = 5
            dstDitherTable(1, 2) = 3
            dstDitherTable(2, 2) = 1
            
            ditherDivisor = 48
            
            xLeft = -2
            xRight = 2
            yDown = 2
            
        Case PDDM_Stucki
        
            ReDim dstDitherTable(-2 To 2, 0 To 2) As Byte
            
            dstDitherTable(1, 0) = 8
            dstDitherTable(2, 0) = 4
            dstDitherTable(-2, 1) = 2
            dstDitherTable(-1, 1) = 4
            dstDitherTable(0, 1) = 8
            dstDitherTable(1, 1) = 4
            dstDitherTable(2, 1) = 2
            dstDitherTable(-2, 2) = 1
            dstDitherTable(-1, 2) = 2
            dstDitherTable(0, 2) = 4
            dstDitherTable(1, 2) = 2
            dstDitherTable(2, 2) = 1
            
            ditherDivisor = 42
            
            xLeft = -2
            xRight = 2
            yDown = 2
            
        Case PDDM_Burkes
        
            ReDim dstDitherTable(-2 To 2, 0 To 1) As Byte
            
            dstDitherTable(1, 0) = 8
            dstDitherTable(2, 0) = 4
            dstDitherTable(-2, 1) = 2
            dstDitherTable(-1, 1) = 4
            dstDitherTable(0, 1) = 8
            dstDitherTable(1, 1) = 4
            dstDitherTable(2, 1) = 2
            
            ditherDivisor = 32
            
            xLeft = -2
            xRight = 2
            yDown = 1
            
        Case PDDM_Sierra3
        
            ReDim dstDitherTable(-2 To 2, 0 To 2) As Byte
            
            dstDitherTable(1, 0) = 5
            dstDitherTable(2, 0) = 3
            dstDitherTable(-2, 1) = 2
            dstDitherTable(-1, 1) = 4
            dstDitherTable(0, 1) = 5
            dstDitherTable(1, 1) = 4
            dstDitherTable(2, 1) = 2
            dstDitherTable(-2, 2) = 0
            dstDitherTable(-1, 2) = 2
            dstDitherTable(0, 2) = 3
            dstDitherTable(1, 2) = 2
            dstDitherTable(2, 2) = 0
            
            ditherDivisor = 32
            
            xLeft = -2
            xRight = 2
            yDown = 2
            
        Case PDDM_SierraTwoRow
            
            ReDim dstDitherTable(-2 To 2, 0 To 1) As Byte
            
            dstDitherTable(1, 0) = 4
            dstDitherTable(2, 0) = 3
            dstDitherTable(-2, 1) = 1
            dstDitherTable(-1, 1) = 2
            dstDitherTable(0, 1) = 3
            dstDitherTable(1, 1) = 2
            dstDitherTable(2, 1) = 1
            
            ditherDivisor = 16
            
            xLeft = -2
            xRight = 2
            yDown = 1
        
        Case PDDM_SierraLite
        
            ReDim dstDitherTable(-1 To 1, 0 To 1) As Byte
            
            dstDitherTable(1, 0) = 2
            dstDitherTable(-1, 1) = 1
            dstDitherTable(0, 1) = 1
            
            ditherDivisor = 4
            
            xLeft = -1
            xRight = 1
            yDown = 1
            
        Case PDDM_Atkinson
            
            ReDim dstDitherTable(-1 To 2, 0 To 2) As Byte
            
            dstDitherTable(1, 0) = 1
            dstDitherTable(2, 0) = 1
            dstDitherTable(-1, 1) = 1
            dstDitherTable(0, 1) = 1
            dstDitherTable(1, 1) = 1
            dstDitherTable(0, 2) = 1
            
            ditherDivisor = 8
            
            xLeft = -1
            xRight = 2
            yDown = 2
            
        Case Else
            GetDitherTable = False
    
    End Select
    
End Function

'Display PD's generic palette load dialog.  All supported palette filetypes will be available to the user.
Public Function DisplayPaletteLoadDialog(ByRef srcFilename As String, ByRef dstFilename As String) As Boolean
    
    DisplayPaletteLoadDialog = False
    
    'Disable user input until the dialog closes
    Interface.DisableUserInput
    
    Dim cdFilter As pdString
    Set cdFilter = New pdString
    cdFilter.Append g_Language.TranslateMessage("All supported palettes") & "|*.aco;*.act;*.ase;*.gpl;*.pal;*.psppalette;*.txt|"
    cdFilter.Append g_Language.TranslateMessage("Adobe Color Swatch") & " (.aco)|*.aco|"
    cdFilter.Append g_Language.TranslateMessage("Adobe Color Table") & " (.act)|*.act|"
    cdFilter.Append g_Language.TranslateMessage("Adobe Swatch Exchange") & " (.ase)|*.ase|"
    cdFilter.Append g_Language.TranslateMessage("GIMP Palette") & " (.gpl)|*.gpl|"
    cdFilter.Append g_Language.TranslateMessage("PaintShop Pro Palette") & " (.pal, .psppalette)|*.pal;*.psppalette|"
    cdFilter.Append g_Language.TranslateMessage("Paint.NET Palette") & " (.txt)|*.txt|"
    cdFilter.Append g_Language.TranslateMessage("All files") & "|*.*"
    
    Dim cdTitle As String
    cdTitle = g_Language.TranslateMessage("Select a palette")
            
    'Prep a common dialog interface
    Dim openDialog As pdOpenSaveDialog
    Set openDialog = New pdOpenSaveDialog
            
    Dim sFile As String
    sFile = srcFilename
    
    If openDialog.GetOpenFileName(sFile, , True, False, cdFilter.ToString(), 1, UserPrefs.GetPalettePath, cdTitle, , GetModalOwner().hWnd) Then
    
        'By design, we don't perform any validation here.  Let the caller validate the file as much (or as little)
        ' as they require.
        DisplayPaletteLoadDialog = (LenB(sFile) <> 0)
        
        'The dialog was successful.  Return the path, and save this path for future usage.
        If DisplayPaletteLoadDialog Then
            UserPrefs.SetPalettePath sFile
            dstFilename = sFile
        Else
            dstFilename = vbNullString
        End If
        
    End If
    
    'Re-enable user input
    Interface.EnableUserInput
    
End Function

'Display PD's generic palette export dialog.  All supported palette filetypes will be available to the user.
Public Function DisplayPaletteSaveDialog(ByRef srcImage As pdImage, ByRef dstFilename As String, ByRef dstFormat As PD_PaletteFormat) As Boolean
    
    DisplayPaletteSaveDialog = False
    
    'Disable user input until the dialog closes
    Interface.DisableUserInput
    
    'Prior to showing the "save palette" dialog, we need to determine three things:
    ' 1) An initial folder
    ' 2) What palette format to suggest
    ' 3) What filename to suggest (*without* a file extension)
    ' 4) What filename + extension to suggest, based on the results of 2 and 3
    
    'Each of these will be handled in turn
    
    '1) Determine an initial folder.  This is easy - just grab the last "palette" path from the preferences file.
    '   (The preferences engine will automatically pass us PD's local palette folder if no "last path" entry exists.)
    Dim initialSaveFolder As String
    initialSaveFolder = UserPrefs.GetPalettePath
    
    '2) What palette format to suggest.  After building the export palette list, retrieve the last-used palette
    '   format index from the user prefs file.
    Dim cdFilter As pdString, cdFilterExtensions As pdString
    Set cdFilter = New pdString
    Set cdFilterExtensions = New pdString
    
    cdFilter.Append g_Language.TranslateMessage("Adobe Color Swatch") & " (.aco)|*.aco|"
    cdFilterExtensions.Append ".aco|"
    cdFilter.Append g_Language.TranslateMessage("Adobe Color Table") & " (.act)|*.act|"
    cdFilterExtensions.Append ".act|"
    cdFilter.Append g_Language.TranslateMessage("Adobe Swatch Exchange") & " (.ase)|*.ase|"
    cdFilterExtensions.Append ".ase|"
    cdFilter.Append g_Language.TranslateMessage("GIMP Palette") & " (.gpl)|*.gpl|"
    cdFilterExtensions.Append ".gpl|"
    cdFilter.Append g_Language.TranslateMessage("PaintShop Pro Palette") & " (.pal)|*.pal|"
    cdFilterExtensions.Append ".pal|"
    cdFilter.Append g_Language.TranslateMessage("Paint.NET Palette") & " (.txt)|*.txt|"
    cdFilterExtensions.Append ".txt"
    
    Dim cdIndex As PD_PaletteFormat
    cdIndex = UserPrefs.GetPref_Long("Saving", "Palette Format", pdpf_AdobeSwatchExchange) + 1
    
    '3) What palette name to suggest.  At present, we just reuse the current image's name.
    Dim palFileName As String
    palFileName = srcImage.ImgStorage.GetEntry_String("OriginalFileName", vbNullString)
    If (LenB(palFileName) = 0) Then palFileName = g_Language.TranslateMessage("New palette")
    palFileName = initialSaveFolder & palFileName
    
    Dim cdTitle As String
    cdTitle = g_Language.TranslateMessage("Export palette")
    
    'Prep a common dialog interface
    Dim saveDialog As pdOpenSaveDialog
    Set saveDialog = New pdOpenSaveDialog
    
    If saveDialog.GetSaveFileName(palFileName, , True, cdFilter.ToString(), cdIndex, UserPrefs.GetPalettePath, cdTitle, cdFilterExtensions.ToString(), GetModalOwner().hWnd) Then
    
        'Update preferences
        UserPrefs.SetPref_Long "Saving", "Palette Format", cdIndex - 1
        UserPrefs.SetPalettePath Files.FileGetPath(palFileName)
        
        'Notify the caller of the new settings
        dstFilename = palFileName
        dstFormat = cdIndex - 1
        DisplayPaletteSaveDialog = True
        
    End If
    
    'Re-enable user input
    Interface.EnableUserInput
    
End Function

Public Function ExportCurrentImagePalette(ByRef srcImage As pdImage, Optional ByVal exportParams As String = vbNullString) As Boolean
    
    'At present, a source image is *required*
    If (srcImage Is Nothing) Then Exit Function
    
    'Start by getting a destination filename and palette format from the user
    Dim dstFilename As String, dstFormat As PD_PaletteFormat
    If Palettes.DisplayPaletteSaveDialog(srcImage, dstFilename, dstFormat) Then
    
        'Before exporting, we need to get export preferences for the current format.  (Some formats support
        ' additional custom features; others do not.)
        
        'Disable user input until the next dialog closes
        Interface.DisableUserInput
        
        Dim exportSettings As String
        If (DialogManager.PromptPaletteSettings(srcImage, dstFormat, dstFilename, exportSettings) = vbOK) Then
            
            Message "Exporting palette..."
            
            'Parse settings and perform the actual export
            Dim cParams As pdParamXML
            Set cParams = New pdParamXML
            cParams.SetParamString exportSettings
            
            Dim cPalette As pdPalette
            Set cPalette = New pdPalette
            
            Dim numColors As Long, optColors As Long
            Dim palName As String
            
            With cParams
                
                'Before retrieving the actual palette, retrieve the number of colors we need to use.
                ' (If we have to generate an optimal palette, we want to know this in advance.)
                numColors = .GetLong("numColors", -1)
                If (numColors <= 0) Then
                    If (dstFormat = pdpf_PaintDotNet) Then optColors = 96 Else optColors = 256
                Else
                    optColors = numColors
                End If
                
                If (.GetLong("srcPalette", 0) = 1) And srcImage.HasOriginalPalette Then
                    srcImage.GetOriginalPalette cPalette
                    If (optColors < cPalette.GetPaletteColorCount()) Then cPalette.SetNewPaletteCount optColors
                Else
                    Dim tmpDIB As pdDIB, tmpQuads() As RGBQuad
                    srcImage.GetCompositedImage tmpDIB, False
                    If Palettes.GetOptimizedPalette(tmpDIB, tmpQuads, optColors, pdqs_Variance) Then cPalette.CreateFromPaletteArray tmpQuads, UBound(tmpQuads) + 1
                End If
                
                'Palette name won't always be used, but retrieve and set it anyway
                palName = .GetString("palName", vbNullString)
                cPalette.SetPaletteName palName
                
                'The actual export is handled by the palette object itself!
                If (cPalette.GetPaletteColorCount() > 0) Then
                
                    If (dstFormat = pdpf_AdobeColorSwatch) Then
                        ExportCurrentImagePalette = cPalette.SavePaletteAdobeSwatch(dstFilename)
                    ElseIf (dstFormat = pdpf_AdobeColorTable) Then
                        ExportCurrentImagePalette = cPalette.SavePaletteAdobeColorTable(dstFilename)
                    ElseIf (dstFormat = pdpf_AdobeSwatchExchange) Then
                        
                        'ASE is a unique format is it supports multiple embedded palettes, and we allow the
                        ' user to overwrite *OR* append this palette to an existing file, if any.
                        Dim tmpPalette As pdPalette
                        If (.GetLong("embedPaletteASE", 0) = 1) And Files.FileExists(dstFilename) Then
                        
                            'The user wants us to merge this palette with the existing file.  Yay?
                            
                            'Start by retrieving the current file; if this fails, we'll default to just writing
                            ' the current palette as-is.
                            Set tmpPalette = New pdPalette
                            If tmpPalette.LoadPaletteFromFile(dstFilename, False) Then
                            
                                'The palette appears to have loaded okay.  Append this palette to the end of it,
                                ' and if that works, swap palette references.
                                If tmpPalette.AppendExistingPalette(cPalette) Then Set cPalette = tmpPalette
                                
                            End If
                            
                        Else
                            'Standard behavior: overwrite the target file.  We don't need to do anything here.
                        End If
                        
                        ExportCurrentImagePalette = cPalette.SavePaletteAdobeSwatchExchange(dstFilename)
                        
                    ElseIf (dstFormat = pdpf_GIMP) Then
                        ExportCurrentImagePalette = cPalette.SavePaletteGIMP(dstFilename)
                    ElseIf (dstFormat = pdpf_PaintDotNet) Then
                        ExportCurrentImagePalette = cPalette.SavePalettePaintDotNet(dstFilename)
                    ElseIf (dstFormat = pdpf_PSP) Then
                        ExportCurrentImagePalette = cPalette.SavePalettePaintShopPro(dstFilename)
                    End If
                    
                End If
                
            End With
        
        End If
        
        'Re-enable user input
        Interface.EnableUserInput
    
    End If
    
    Message "Finished."

End Function

'Several PD functions share the same dither features (monochrome, grayscale, color palettes, etc)
Public Sub PopulateDitheringDropdown(ByRef dstDropDown As pdDropDown)
    dstDropDown.SetAutomaticRedraws False
    dstDropDown.Clear
    dstDropDown.AddItem "None", 0
    dstDropDown.AddItem "Ordered (Bayer 4x4)", 1
    dstDropDown.AddItem "Ordered (Bayer 8x8)", 2
    dstDropDown.AddItem "Single neighbor", 3
    dstDropDown.AddItem "Floyd-Steinberg", 4
    dstDropDown.AddItem "Jarvis, Judice, and Ninke", 5
    dstDropDown.AddItem "Stucki", 6
    dstDropDown.AddItem "Burkes", 7
    dstDropDown.AddItem "Sierra-3", 8
    dstDropDown.AddItem "Two-Row Sierra", 9
    dstDropDown.AddItem "Sierra Lite", 10
    dstDropDown.AddItem "Atkinson / Classic Macintosh", 11
    dstDropDown.SetAutomaticRedraws True
End Sub
