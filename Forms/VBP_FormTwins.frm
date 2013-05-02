VERSION 5.00
Begin VB.Form FormTwins 
   AutoRedraw      =   -1  'True
   BackColor       =   &H80000005&
   BorderStyle     =   4  'Fixed ToolWindow
   Caption         =   " Generate Twins"
   ClientHeight    =   6525
   ClientLeft      =   -15
   ClientTop       =   225
   ClientWidth     =   9555
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   LinkTopic       =   "Form1"
   MaxButton       =   0   'False
   MinButton       =   0   'False
   ScaleHeight     =   435
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   637
   ShowInTaskbar   =   0   'False
   StartUpPosition =   1  'CenterOwner
   Begin PhotoDemon.smartOptionButton optTwins 
      Height          =   375
      Index           =   0
      Left            =   6960
      TabIndex        =   5
      Top             =   2640
      Width           =   1440
      _ExtentX        =   2540
      _ExtentY        =   661
      Caption         =   "horizontal"
      Value           =   -1  'True
      BeginProperty Font {0BE35203-8F91-11CE-9DE3-00AA004BB851} 
         Name            =   "Tahoma"
         Size            =   12
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
   End
   Begin VB.CommandButton CmdOK 
      Caption         =   "&OK"
      Default         =   -1  'True
      Height          =   495
      Left            =   6600
      TabIndex        =   0
      Top             =   5910
      Width           =   1365
   End
   Begin VB.CommandButton CmdCancel 
      Cancel          =   -1  'True
      Caption         =   "&Cancel"
      Height          =   495
      Left            =   8070
      TabIndex        =   1
      Top             =   5910
      Width           =   1365
   End
   Begin PhotoDemon.fxPreviewCtl fxPreview 
      Height          =   5625
      Left            =   120
      TabIndex        =   3
      Top             =   120
      Width           =   5625
      _ExtentX        =   9922
      _ExtentY        =   9922
   End
   Begin PhotoDemon.smartOptionButton optTwins 
      Height          =   375
      Index           =   1
      Left            =   6960
      TabIndex        =   6
      Top             =   3090
      Width           =   1140
      _ExtentX        =   2011
      _ExtentY        =   661
      Caption         =   "vertical"
      BeginProperty Font {0BE35203-8F91-11CE-9DE3-00AA004BB851} 
         Name            =   "Tahoma"
         Size            =   12
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
   End
   Begin VB.Label lblAlgorithm 
      AutoSize        =   -1  'True
      BackStyle       =   0  'Transparent
      Caption         =   "twin orientation:"
      BeginProperty Font 
         Name            =   "Tahoma"
         Size            =   12
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
      ForeColor       =   &H00404040&
      Height          =   285
      Left            =   6720
      TabIndex        =   4
      Top             =   2160
      Width           =   1755
   End
   Begin VB.Label lblBackground 
      BeginProperty Font 
         Name            =   "MS Sans Serif"
         Size            =   8.25
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
      Height          =   855
      Left            =   0
      TabIndex        =   2
      Top             =   5760
      Width           =   11295
   End
End
Attribute VB_Name = "FormTwins"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
'***************************************************************************
'"Twin" Filter Interface
'Copyright �2000-2013 by Tanner Helland
'Created: 6/12/01
'Last updated: 10/September/12
'Last update: rewrote twin algorithm against new layer class
'
'Unoptimized "twin" generator.  Simple 50% alpha blending combined with a flip.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://www.tannerhelland.com/photodemon/#license
'
'***************************************************************************

Option Explicit

'CANCEL button
Private Sub CmdCancel_Click()
    Unload Me
End Sub

'OK button
Private Sub cmdOK_Click()
    Me.Visible = False
    If optTwins(0).Value Then Process Twins, 0 Else Process Twins, 1
    Unload Me
End Sub

'This routine mirrors and alphablends an image, making it "tilable" or symmetrical
Public Sub GenerateTwins(ByVal tType As Byte, Optional ByVal toPreview As Boolean = False, Optional ByRef dstPic As fxPreviewCtl)
   
    If toPreview = False Then Message "Generating image twin..."
    
    'Create a local array and point it at the pixel data of the current image
    Dim dstImageData() As Byte
    Dim dstSA As SAFEARRAY2D
    prepImageData dstSA, toPreview, dstPic
    CopyMemory ByVal VarPtrArray(dstImageData()), VarPtr(dstSA), 4
    
    'Create a second local array.  This will contain the a copy of the current image, and we will use it as our source reference
    ' (This is necessary to prevent already-processed pixels from affecting the results of later pixels.)
    Dim srcImageData() As Byte
    Dim srcSA As SAFEARRAY2D
    
    Dim srcLayer As pdLayer
    Set srcLayer = New pdLayer
    srcLayer.createFromExistingLayer workingLayer
    
    prepSafeArray srcSA, srcLayer
    CopyMemory ByVal VarPtrArray(srcImageData()), VarPtr(srcSA), 4
        
    'Local loop variables can be more efficiently cached by VB's compiler, so we transfer all relevant loop data here
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = curLayerValues.Left
    initY = curLayerValues.Top
    finalX = curLayerValues.Right
    finalY = curLayerValues.Bottom
            
    'These values will help us access locations in the array more quickly.
    ' (qvDepth is required because the image array may be 24 or 32 bits per pixel, and we want to handle both cases.)
    Dim QuickVal As Long, qvDepth As Long
    qvDepth = curLayerValues.BytesPerPixel
    
    'Pre-calculate the largest possible processed x-value
    Dim MaxX As Long
    MaxX = finalX * qvDepth
    
    'To keep processing quick, only update the progress bar when absolutely necessary.  This function calculates that value
    ' based on the size of the area to be processed.
    Dim progBarCheck As Long
    progBarCheck = findBestProgBarValue()
            
    'This look-up table will be used for alpha-blending.  It contains the equivalent of any two color values [0,255] added
    ' together and divided by 2.
    Dim hLookup(0 To 510) As Byte
    For x = 0 To 510
        hLookup(x) = x \ 2
    Next x
    
    'Color variables
    Dim r As Long, g As Long, b As Long
    Dim r2 As Long, g2 As Long, b2 As Long
    
    'Loop through each pixel in the image, converting values as we go
    For x = initX To finalX
        QuickVal = x * qvDepth
    For y = initY To finalY
    
        'Grab the current pixel values
        r = srcImageData(QuickVal + 2, y)
        g = srcImageData(QuickVal + 1, y)
        b = srcImageData(QuickVal, y)
        
        'Grab the value of the "second" pixel, whose position will vary depending on the method (vertical or horizontal)
        If tType = 0 Then
            r2 = srcImageData(MaxX - QuickVal + 2, y)
            g2 = srcImageData(MaxX - QuickVal + 1, y)
            b2 = srcImageData(MaxX - QuickVal, y)
        Else
            r2 = srcImageData(QuickVal + 2, finalY - y)
            g2 = srcImageData(QuickVal + 1, finalY - y)
            b2 = srcImageData(QuickVal, finalY - y)
        End If
        
        'Alpha-blend the two pixels using our shortcut look-up table
        dstImageData(QuickVal + 2, y) = hLookup(r + r2)
        dstImageData(QuickVal + 1, y) = hLookup(g + g2)
        dstImageData(QuickVal, y) = hLookup(b + b2)
        
    Next y
        If toPreview = False Then
            If (x And progBarCheck) = 0 Then SetProgBarVal x
        End If
    Next x
    
    'With our work complete, point both ImageData() arrays away from their DIBs and deallocate them
    CopyMemory ByVal VarPtrArray(srcImageData), 0&, 4
    Erase srcImageData
    
    CopyMemory ByVal VarPtrArray(dstImageData), 0&, 4
    Erase dstImageData
    
    'Pass control to finalizeImageData, which will handle the rest of the rendering
    finalizeImageData toPreview, dstPic
        
End Sub

Private Sub Form_Activate()
        
    'Assign the system hand cursor to all relevant objects
    makeFormPretty Me
    
    'Render an image preview
    GenerateTwins 0, True, fxPreview
    
End Sub

Private Sub Form_Unload(Cancel As Integer)
    ReleaseFormTheming Me
End Sub

Private Sub optTwins_Click(Index As Integer)
    GenerateTwins Index, True, fxPreview
End Sub
