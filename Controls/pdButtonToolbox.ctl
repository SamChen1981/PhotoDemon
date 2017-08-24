VERSION 5.00
Begin VB.UserControl pdButtonToolbox 
   Appearance      =   0  'Flat
   BackColor       =   &H80000005&
   ClientHeight    =   3600
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   4800
   ClipBehavior    =   0  'None
   DrawStyle       =   5  'Transparent
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   HasDC           =   0   'False
   HitBehavior     =   0  'None
   PaletteMode     =   4  'None
   ScaleHeight     =   240
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   320
   ToolboxBitmap   =   "pdButtonToolbox.ctx":0000
End
Attribute VB_Name = "pdButtonToolbox"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Toolbox Button control
'Copyright 2014-2017 by Tanner Helland
'Created: 19/October/14
'Last updated: 14/February/16
'Last update: finalize theming support
'
'In a surprise to precisely no one, PhotoDemon has some unique needs when it comes to user controls - needs that
' the intrinsic VB controls can't handle.  These range from the obnoxious (lack of an "autosize" property for
' anything but labels) to the critical (no Unicode support).
'
'As such, I've created many of my own UCs for the program.  All are owner-drawn, with the goal of maintaining
' visual fidelity across the program, while also enabling key features like Unicode support.
'
'A few notes on this toolbox button control, specifically:
'
' 1) Why make a separate control for toolbox buttons?  I could add a style property to the regular PD button, but I don't
'     like the complications that introduces.  "Do one thing and do it well" is the idea with PD user controls.
' 2) High DPI settings are handled automatically.
' 3) A hand cursor is automatically applied, and clicks are returned via the Click event.
' 4) Coloration is automatically handled by PD's internal theming engine.
' 5) This button does not support text, by design.  It is image-only.
' 6) This button does not automatically set its Value property when clicked.  It simply raises a Click() event.  This is
'     by design to make it easier to toggle state in the toolbox maintenance code.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'This control really only needs one event raised - Click
Public Event Click()

'Because VB focus events are wonky, especially when we use CreateWindow within a UC, this control raises its own
' specialized focus events.  If you need to track focus, use these instead of the default VB functions.
Public Event GotFocusAPI()
Public Event LostFocusAPI()

'Current button state; TRUE if down, FALSE if up.  Note that this may not correspond with mouse state, depending on
' button properties (buttons can toggle in various ways).
Private m_ButtonState As Boolean

'Three distinct button images - normal, hover, and disabled - are auto-generated by this control, and stored to a single
' sprite-sheet style DIB.  The caller must supply the normal image as a reference.
' (Also, since this control doesn't support text, you must make use of these!)
Private m_ButtonImages As pdDIB
Private m_ButtonWidth As Long, m_ButtonHeight As Long

'As of Feb 2015, this control also supports unique images when depressed.  This feature is optional!
Private btImage_Pressed As pdDIB
Private btImageHover_Pressed As pdDIB   'Auto-created hover (glow) version of the image.

'(x, y) position of the button image.  This is auto-calculated by the control.
Private btImageCoords As POINTAPI

'Current back color.  Because this control sits on a variety of places in PD (like the canvas status bar), its BackColor
' sometimes needs to be set manually.  (Note that this custom value will not be used unless m_UseCustomBackColor is TRUE!)
Private m_BackColor As OLE_COLOR, m_UseCustomBackColor As Boolean

'AutoToggle mode allows the button to operate as a normal button (e.g. no persistent value)
Private m_AutoToggle As Boolean

'StickyToggle mode allows the button to operate as a checkbox (e.g. a persistent value, that switches on every click)
Private m_StickyToggle As Boolean

'In some circumstances, an image alone is sufficient for indicating "pressed" state.  This value tells the control to *not* render a custom
' highlight state when a button is depressed.
Private m_DontHighlightDownState As Boolean

'User control support class.  Historically, many classes (and associated subclassers) were required by each user control,
' but I've since attempted to wrap these into a single master control support class.
Private WithEvents ucSupport As pdUCSupport
Attribute ucSupport.VB_VarHelpID = -1

'Local list of themable colors.  This list includes all potential colors used by the control, regardless of state change
' or internal control settings.  The list is updated by calling the UpdateColorList function.
' (Note also that this list does not include variants, e.g. "BorderColor" vs "BorderColor_Hovered".  Variant values are
'  automatically calculated by the color management class, and they are retrieved by passing boolean modifiers to that
'  class, rather than treating every imaginable variant as a separate constant.)
Private Enum PDTOOLBUTTON_COLOR_LIST
    [_First] = 0
    PDTB_Background = 0
    PDTB_ButtonFill = 1
    PDTB_Border = 2
    [_Last] = 2
    [_Count] = 3
End Enum

'Color retrieval and storage is handled by a dedicated class; this allows us to optimize theme interactions,
' without worrying about the details locally.
Private m_Colors As pdThemeColors

Public Function GetControlType() As PD_ControlType
    GetControlType = pdct_ButtonToolbox
End Function

Public Function GetControlName() As String
    GetControlName = UserControl.Extender.Name
End Function

'This toolbox button control is designed to be used in a "radio button"-like system, where buttons exist in a group, and the
' pressing of one results in the unpressing of any others.  For the rare circumstances where this behavior is undesirable
' (e.g. the pdCanvas status bar, where some instances of this control serve as actual buttons), the AutoToggle property can
' be set to TRUE.  This will cause the button to operate as a normal command button, which depresses on MouseDown and raises
' on MouseUp.
Public Property Get AutoToggle() As Boolean
    AutoToggle = m_AutoToggle
End Property

Public Property Let AutoToggle(ByVal newToggle As Boolean)
    m_AutoToggle = newToggle
End Property

'BackColor is an important property for this control, as it may sit on other controls whose backcolor is not guaranteed in advance.
' So we can't rely on theming alone to determine this value.
Public Property Get BackColor() As OLE_COLOR
    BackColor = m_BackColor
End Property

Public Property Let BackColor(ByVal newBackColor As OLE_COLOR)
    m_BackColor = newBackColor
    RedrawBackBuffer
End Property

'In some circumstances, an image alone is sufficient for indicating "pressed" state.  This value tells the control to *not* render a custom
' highlight state when button state is TRUE (pressed).
Public Property Get DontHighlightDownState() As Boolean
    DontHighlightDownState = m_DontHighlightDownState
End Property

Public Property Let DontHighlightDownState(ByVal newState As Boolean)
    m_DontHighlightDownState = newState
    If Value Then RedrawBackBuffer
End Property

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
Attribute Enabled.VB_UserMemId = -514
    Enabled = UserControl.Enabled
End Property

Public Property Let Enabled(ByVal newValue As Boolean)
    UserControl.Enabled = newValue
    PropertyChanged "Enabled"
    If ucSupport.AmIVisible Then RedrawBackBuffer
End Property

'Sticky toggle allows this button to operate as a checkbox, where each click toggles its value.  If I was smart, I would have implemented
' the button's toggle behavior as a single property with multiple enum values, but I didn't think of it in advance, so now I'm stuck
' with this.  Do not set both StickyToggle and AutoToggle, as the button will not behave correctly.
Public Property Get StickyToggle() As Boolean
    StickyToggle = m_StickyToggle
End Property

Public Property Let StickyToggle(ByVal newValue As Boolean)
    m_StickyToggle = newValue
End Property

'hWnds aren't exposed by default
Public Property Get hWnd() As Long
Attribute hWnd.VB_UserMemId = -515
    hWnd = UserControl.hWnd
End Property

'Container hWnd must be exposed for external tooltip handling
Public Property Get ContainerHwnd() As Long
    ContainerHwnd = UserControl.ContainerHwnd
End Property

'The most relevant part of this control is this Value property, which is important since this button operates as a toggle.
Public Property Get Value() As Boolean
    Value = m_ButtonState
End Property

Public Property Let Value(ByVal newValue As Boolean)
    
    'Update our internal value tracker, but only if autotoggle is not active.  (Autotoggle causes the button to behave like
    ' a normal button, so there's no concept of a persistent "value".)
    If (m_ButtonState <> newValue) And (Not m_AutoToggle) Then
    
        m_ButtonState = newValue
        
        'Redraw the control to match the new state
        RedrawBackBuffer
        
        'Note that we don't raise a Click event here.  This is by design.  The toolbox handles all toggle code for these buttons,
        ' and it's more efficient to let it handle this, as it already has a detailed notion of things like program state, which
        ' affects whether buttons are clickable, etc.
        
        'As such, the Click event is not raised for Value changes alone - only for actions initiated by actual user input.
        
    End If
    
End Property

Public Property Get UseCustomBackColor() As Boolean
    UseCustomBackColor = m_UseCustomBackColor
End Property

Public Property Let UseCustomBackColor(ByVal newValue As Boolean)
    m_UseCustomBackColor = newValue
    RedrawBackBuffer
    PropertyChanged "UseCustomBackColor"
End Property

'Assign a DIB to this button.  Matching disabled and hover state DIBs are automatically generated.
' Note that you can supply an existing DIB, or a resource name.  You must supply one or the other (obviously).
' No preprocessing is currently applied to DIBs loaded as a resource.
Public Sub AssignImage(Optional ByVal resName As String = vbNullString, Optional ByRef srcDIB As pdDIB = Nothing, Optional ByVal useImgWidth As Long = 0, Optional ByVal useImgHeight As Long = 0, Optional ByVal imgBorderSizeIfAny As Long = 0)
    
    'This is a temporary workaround for AssignImage calls that do not supply the desired width/height.
    ' (As of 7.0, callers must *always* specify a desired size at 100% DPI, because resources are stored
    ' at multiple sizes!)
    If (useImgWidth = 0) Then useImgWidth = (ucSupport.GetBackBufferWidth \ 8) * 8
    If (useImgHeight = 0) Then useImgHeight = (ucSupport.GetBackBufferHeight \ 8) * 8
    
    'Load the requested resource DIB, as necessary.  (I say "as necessary" because the caller can supply the DIB as-is, too.)
    If (Len(resName) <> 0) Then LoadResourceToDIB resName, srcDIB, useImgWidth, useImgHeight, imgBorderSizeIfAny
    If (srcDIB Is Nothing) Then Exit Sub
    
    'Cache the width and height of the DIB; it serves as our reference measurements for subsequent blt operations.
    ' (We also check for these != 0 to verify that an image was successfully loaded.)
    m_ButtonWidth = srcDIB.GetDIBWidth
    m_ButtonHeight = srcDIB.GetDIBHeight
    
    If (m_ButtonWidth <> 0) And (m_ButtonHeight <> 0) Then
    
        'Unpremultiply the source image
        Dim initAlphaState As Boolean
        initAlphaState = srcDIB.GetAlphaPremultiplication
        If initAlphaState Then srcDIB.SetAlphaPremultiplication False
        
        'Create our vertical sprite-sheet DIB, and mark it as having premultiplied alpha
        If (m_ButtonImages Is Nothing) Then Set m_ButtonImages = New pdDIB
        m_ButtonImages.CreateBlank m_ButtonWidth, m_ButtonHeight * 3, srcDIB.GetDIBColorDepth, 0, 0
        m_ButtonImages.SetInitialAlphaPremultiplicationState False
        
        'Copy the normal DIB into place at the top of the sheet
        BitBlt m_ButtonImages.GetDIBDC, 0, 0, m_ButtonWidth, m_ButtonHeight, srcDIB.GetDIBDC, 0, 0, vbSrcCopy
        
        'A separate function will automatically generate "glowy hovered" and "grayscale disabled" versions for us
        GenerateVariantButtonImages
        
        'Reset alpha premultiplication
        m_ButtonImages.SetAlphaPremultiplication True
        If (Len(resName) = 0) Then
            If initAlphaState Then srcDIB.SetAlphaPremultiplication True
        End If
        
        m_ButtonImages.FreeFromDC
        
    End If
    
    'Request a control layout update, which will also calculate a centered position for the new image
    UpdateControlLayout

End Sub

'After loading the initial button DIB and creating a matching spritesheet, call this function to fill the rest of
' the spritesheet with the "glowy hovered" and "grayscale disabled" button image variants.
Private Sub GenerateVariantButtonImages()
    
    'Start by building two lookup tables: one for the hovered image, and a second one for the disabled image
    Dim hLookup() As Byte
    ReDim hLookup(0 To 255) As Byte
    
    Dim newPxColor As Long, x As Long, y As Long
    For x = 0 To 255
        newPxColor = x + UC_HOVER_BRIGHTNESS
        If (newPxColor > 255) Then newPxColor = 255
        hLookup(x) = newPxColor
    Next x
    
    'Grab direct access to the spritesheet's bytes
    Dim srcPixels() As Byte, tmpSA As SAFEARRAY2D
    PrepSafeArray tmpSA, m_ButtonImages
    CopyMemory ByVal VarPtrArray(srcPixels()), VarPtr(tmpSA), 4
    
    Dim initY As Long, finalY As Long, offsetY As Long
    initY = m_ButtonHeight
    finalY = m_ButtonHeight + (m_ButtonHeight - 1)
    offsetY = m_ButtonHeight
    
    Dim initX As Long, finalX As Long
    initX = 0
    finalX = (m_ButtonWidth - 1) * 4
    
    Dim a As Long, tmpY As Long
    
    'Paint the hovered segment of the sprite strip
    For y = initY To finalY
        tmpY = y - offsetY
    For x = initX To finalX Step 4
        a = srcPixels(x + 3, tmpY)
        If (a <> 0) Then
            srcPixels(x, y) = hLookup(srcPixels(x, tmpY))
            srcPixels(x + 1, y) = hLookup(srcPixels(x + 1, tmpY))
            srcPixels(x + 2, y) = hLookup(srcPixels(x + 2, tmpY))
            srcPixels(x + 3, y) = a
        End If
    Next x
    Next y
    
    'Paint the disabled segment of the sprite strip.  (For this, note that we use a theme-level disabled color.)
    Dim disabledColor As Long
    disabledColor = g_Themer.GetGenericUIColor(UI_ImageDisabled)
    
    Dim dR As Integer, dG As Integer, dB As Integer
    dR = Colors.ExtractRed(disabledColor)
    dG = Colors.ExtractGreen(disabledColor)
    dB = Colors.ExtractBlue(disabledColor)
    
    initY = m_ButtonHeight * 2
    finalY = m_ButtonHeight * 2 + (m_ButtonHeight - 1)
    offsetY = m_ButtonHeight * 2
    
    For y = initY To finalY
    For x = initX To finalX Step 4
        a = srcPixels(x + 3, y - offsetY)
        If (a <> 0) Then
            srcPixels(x, y) = dR
            srcPixels(x + 1, y) = dG
            srcPixels(x + 2, y) = dB
            srcPixels(x + 3, y) = a
        End If
    Next x
    Next y
    
    CopyMemory ByVal VarPtrArray(srcPixels), 0&, 4
    
End Sub

'Assign an *OPTIONAL* special DIB to this button, to be used only when the button is pressed.  A disabled-state image is not generated,
' but a hover-state one is.
'
'IMPORTANT NOTE!  To reduce resource usage, PD requires that this optional "pressed" image have identical dimensions to the primary image.
' This greatly simplifies layout and painting issues, so I do not expect to change it.
'
'Note that you can supply an existing DIB, or a resource name.  You must supply one or the other (obviously).  No preprocessing is currently
' applied to DIBs loaded as a resource, but in the future we will need to deal with high-DPI concerns.
Public Sub AssignImage_Pressed(Optional ByVal resName As String = vbNullString, Optional ByRef srcDIB As pdDIB, Optional ByVal useImgWidth As Long = 0, Optional ByVal useImgHeight As Long = 0, Optional ByVal imgBorderSizeIfAny As Long = 0)
    
    'This is a temporary workaround for AssignImage calls that do not supply the desired width/height.
    ' (As of 7.0, callers must *always* specify a desired size at 100% DPI, because resources are stored
    ' at multiple sizes!)
    If (useImgWidth = 0) Then useImgWidth = (ucSupport.GetBackBufferWidth \ 8) * 8
    If (useImgHeight = 0) Then useImgHeight = (ucSupport.GetBackBufferHeight \ 8) * 8
    
    'Load the requested resource DIB, as necessary.  (I say "as necessary" because the caller can supply the DIB as-is, too.)
    If (Len(resName) <> 0) Then LoadResourceToDIB resName, srcDIB, useImgWidth, useImgHeight, imgBorderSizeIfAny
    If (srcDIB Is Nothing) Then Exit Sub
    
    'Start by making a copy of the source DIB
    Set btImage_Pressed = New pdDIB
    btImage_Pressed.CreateFromExistingDIB srcDIB
    
    'Also create a "glowy" hovered version of the DIB for hover state
    Set btImageHover_Pressed = New pdDIB
    btImageHover_Pressed.CreateFromExistingDIB btImage_Pressed
    ScaleDIBRGBValues btImageHover_Pressed, UC_HOVER_BRIGHTNESS, True
    
    btImage_Pressed.FreeFromDC
    btImageHover_Pressed.FreeFromDC
    
    'If the control is currently pressed, request a redraw
    If Value Then RedrawBackBuffer

End Sub

'To support high-DPI settings properly, we expose specialized move+size functions
Public Function GetLeft() As Long
    GetLeft = ucSupport.GetControlLeft
End Function

Public Sub SetLeft(ByVal newLeft As Long)
    ucSupport.RequestNewPosition newLeft, , True
End Sub

Public Function GetTop() As Long
    GetTop = ucSupport.GetControlTop
End Function

Public Sub SetTop(ByVal newTop As Long)
    ucSupport.RequestNewPosition , newTop, True
End Sub

Public Function GetWidth() As Long
    GetWidth = ucSupport.GetControlWidth
End Function

Public Sub SetWidth(ByVal newWidth As Long)
    ucSupport.RequestNewSize newWidth, , True
End Sub

Public Function GetHeight() As Long
    GetHeight = ucSupport.GetControlHeight
End Function

Public Sub SetHeight(ByVal newHeight As Long)
    ucSupport.RequestNewSize , newHeight, True
End Sub

Public Sub SetPosition(ByVal newLeft As Long, ByVal newTop As Long)
    ucSupport.RequestNewPosition newLeft, newTop, True
End Sub

Public Sub SetPositionAndSize(ByVal newLeft As Long, ByVal newTop As Long, ByVal newWidth As Long, ByVal newHeight As Long)
    ucSupport.RequestFullMove newLeft, newTop, newWidth, newHeight, True
End Sub

'A few key events are also handled
Private Sub ucSupport_KeyDownCustom(ByVal Shift As ShiftConstants, ByVal vkCode As Long, markEventHandled As Boolean)
    
    markEventHandled = False
    
    'If space is pressed, and our value is not true, raise a click event.
    If (vkCode = VK_SPACE) Then
        
        markEventHandled = True
        
        If ucSupport.DoIHaveFocus And Me.Enabled Then
        
            'Sticky toggle mode causes the button to toggle between true/false
            If m_StickyToggle Then
            
                Value = (Not Value)
                RedrawBackBuffer
                RaiseEvent Click
            
            'Other modes behave identically
            Else
            
                If (Not m_ButtonState) Then
                    Value = True
                    RedrawBackBuffer
                    RaiseEvent Click
                    
                    'During auto-toggle mode, immediately reverse the value after the Click() event is raised
                    If m_AutoToggle Then
                        m_ButtonState = False
                        RedrawBackBuffer True, False
                    End If
                    
                End If
            
            End If
            
        End If
        
    End If

End Sub

Private Sub ucSupport_KeyDownSystem(ByVal Shift As ShiftConstants, ByVal whichSysKey As PD_NavigationKey, markEventHandled As Boolean)
    
    'Enter/Esc get reported directly to the system key handler.  Note that we track the return, because TRUE
    ' means the key was successfully forwarded to the relevant handler.  (If FALSE is returned, no control
    ' accepted the keypress, meaning we should forward the event down the line.)
    markEventHandled = NavKey.NotifyNavKeypress(Me, whichSysKey, Shift)
    
End Sub

'If space was pressed, and AutoToggle is active, remove the button state and redraw it
Private Sub ucSupport_KeyUpCustom(ByVal Shift As ShiftConstants, ByVal vkCode As Long, markEventHandled As Boolean)
    If (vkCode = VK_SPACE) Then
        If Me.Enabled And Value And m_AutoToggle Then
            Value = False
            RedrawBackBuffer
        End If
    End If
End Sub

'To improve responsiveness, MouseDown is used instead of Click.
' (TODO: switch to MouseUp, so we have a chance to draw the down button state and provide some visual feedback)
Private Sub ucSupport_MouseDownCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal timeStamp As Long)

    If Me.Enabled Then
        
        'Sticky toggle allows the button to operate as a checkbox
        If m_StickyToggle Then
            Value = CBool(Not Value)
        
        'Non-sticky toggle modes will always cause the button to be TRUE on a MouseDown event
        Else
            Value = True
        End If
        
        RedrawBackBuffer True
        RaiseEvent Click
        
        'During auto-toggle mode, immediately reverse the value after the Click() event is raised
        If m_AutoToggle Then
            m_ButtonState = False
            RedrawBackBuffer True, False
        End If
        
    End If
        
End Sub

'Enter/leave events trigger cursor changes and hover-state redraws, so they must be tracked
Private Sub ucSupport_MouseEnter(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    ucSupport.RequestCursor IDC_HAND
    RedrawBackBuffer
End Sub

Private Sub ucSupport_MouseLeave(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    ucSupport.RequestCursor IDC_DEFAULT
    RedrawBackBuffer
End Sub

'If toggle mode is active, remove the button's TRUE state and redraw it
Private Sub ucSupport_MouseUpCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal clickEventAlsoFiring As Boolean, ByVal timeStamp As Long)
    If m_AutoToggle And Value Then Value = False
    RedrawBackBuffer
End Sub

Private Sub ucSupport_GotFocusAPI()
    RaiseEvent GotFocusAPI
    RedrawBackBuffer
End Sub

Private Sub ucSupport_LostFocusAPI()
    RaiseEvent LostFocusAPI
    RedrawBackBuffer
End Sub

Private Sub ucSupport_RepaintRequired(ByVal updateLayoutToo As Boolean)
    If updateLayoutToo Then UpdateControlLayout
    RedrawBackBuffer
End Sub

'INITIALIZE control
Private Sub UserControl_Initialize()
    
    'Initialize a master user control support class
    Set ucSupport = New pdUCSupport
    ucSupport.RegisterControl UserControl.hWnd, True
    ucSupport.RequestExtraFunctionality True, True
    ucSupport.SpecifyRequiredKeys VK_SPACE
    
    'Prep the color manager and load default colors
    Set m_Colors = New pdThemeColors
    Dim colorCount As PDTOOLBUTTON_COLOR_LIST: colorCount = [_Count]
    m_Colors.InitializeColorList "PDToolButton", colorCount
    If Not MainModule.IsProgramRunning() Then UpdateColorList
    
    'Update the control size parameters at least once
    UpdateControlLayout
                
End Sub

'Set default properties
Private Sub UserControl_InitProperties()
    AutoToggle = False
    BackColor = vbWhite
    DontHighlightDownState = False
    StickyToggle = False
    UseCustomBackColor = False
    Value = False
End Sub

'At run-time, painting is handled by the support class.  In the IDE, however, we must rely on VB's internal paint event.
Private Sub UserControl_Paint()
    If Not MainModule.IsProgramRunning() Then ucSupport.RequestIDERepaint UserControl.hDC
End Sub

Private Sub UserControl_ReadProperties(PropBag As PropertyBag)
    With PropBag
        AutoToggle = .ReadProperty("AutoToggle", False)
        BackColor = .ReadProperty("BackColor", vbWhite)
        DontHighlightDownState = .ReadProperty("DontHighlightDownState", False)
        StickyToggle = .ReadProperty("StickyToggle", False)
        UseCustomBackColor = .ReadProperty("UseCustomBackColor", False)
    End With
End Sub

Private Sub UserControl_Resize()
    If (Not MainModule.IsProgramRunning()) Then ucSupport.NotifyIDEResize UserControl.Width, UserControl.Height
End Sub

Private Sub UserControl_WriteProperties(PropBag As PropertyBag)
    With PropBag
        .WriteProperty "AutoToggle", AutoToggle, False
        .WriteProperty "BackColor", BackColor, vbWhite
        .WriteProperty "DontHighlightDownState", DontHighlightDownState, False
        .WriteProperty "StickyToggle", StickyToggle, False
        .WriteProperty "UseCustomBackColor", UseCustomBackColor, False
    End With
End Sub

'Because this control automatically forces all internal buttons to identical sizes, we have to recalculate a number
' of internal sizing metrics whenever the control size changes.
Private Sub UpdateControlLayout()
    
    'Retrieve DPI-aware control dimensions from the support class
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    'Determine positioning of the button image, if any
    If (m_ButtonWidth <> 0) Then
        btImageCoords.x = (bWidth - m_ButtonWidth) \ 2
        btImageCoords.y = (bHeight - m_ButtonHeight) \ 2
    End If
    
End Sub

'Use this function to completely redraw the back buffer from scratch.  Note that this is computationally expensive compared to just flipping the
' existing buffer to the screen, so only redraw the backbuffer if the control state has somehow changed.
Private Sub RedrawBackBuffer(Optional ByVal raiseImmediateDrawEvent As Boolean = False, Optional ByVal testMouseState As Boolean = True)
    
    'Because this control supports so many different behaviors, color decisions are somewhat complicated.  Note that the
    ' control's BackColor property is only relevant under certain conditions (e.g. if the matching UseCustomBackColor
    ' property is set, the button is not pressed, etc).
    Dim btnColorBorder As Long, btnColorFill As Long
    Dim considerActive As Boolean
    considerActive = (m_ButtonState And (Not m_DontHighlightDownState))
    If testMouseState Then considerActive = considerActive Or (m_AutoToggle And ucSupport.IsMouseButtonDown(pdLeftButton))
    
    'If our owner has requested a custom backcolor, it takes precedence (but only if the button is inactive)
    If m_UseCustomBackColor And (Not considerActive) Then
        btnColorFill = m_BackColor
        If ucSupport.IsMouseInside Then
            btnColorBorder = m_Colors.RetrieveColor(PDTB_Border, Me.Enabled, False, True)
        Else
            btnColorBorder = btnColorFill
        End If
    Else
        btnColorFill = m_Colors.RetrieveColor(PDTB_ButtonFill, Me.Enabled, considerActive, ucSupport.IsMouseInside)
        btnColorBorder = m_Colors.RetrieveColor(PDTB_Border, Me.Enabled, considerActive, ucSupport.IsMouseInside)
    End If
    
    'Request the back buffer DC, and ask the support module to erase any existing rendering for us.
    Dim bufferDC As Long, bWidth As Long, bHeight As Long
    bufferDC = ucSupport.GetBackBufferDC(True, btnColorFill)
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
        
    If MainModule.IsProgramRunning() Then
        
        'A single-pixel border is always drawn around the control
        GDI_Plus.GDIPlusDrawRectOutlineToDC bufferDC, 0, 0, bWidth - 1, bHeight - 1, btnColorBorder, 255, 1
        
        'Paint the image, if any
        If (m_ButtonWidth <> 0) Then
            
            If Me.Enabled Then
                If Value And (Not btImage_Pressed Is Nothing) Then
                    If ucSupport.IsMouseInside Then
                        btImageHover_Pressed.AlphaBlendToDC bufferDC, 255, btImageCoords.x, btImageCoords.y
                        btImageHover_Pressed.FreeFromDC
                    Else
                        btImage_Pressed.AlphaBlendToDC bufferDC, 255, btImageCoords.x, btImageCoords.y
                        btImage_Pressed.FreeFromDC
                    End If
                Else
                    If ucSupport.IsMouseInside Then
                        m_ButtonImages.AlphaBlendToDCEx bufferDC, btImageCoords.x, btImageCoords.y, m_ButtonWidth, m_ButtonHeight, 0, m_ButtonHeight, m_ButtonWidth, m_ButtonHeight
                    Else
                        m_ButtonImages.AlphaBlendToDCEx bufferDC, btImageCoords.x, btImageCoords.y, m_ButtonWidth, m_ButtonHeight, 0, 0, m_ButtonWidth, m_ButtonHeight
                    End If
                End If
            Else
                m_ButtonImages.AlphaBlendToDCEx bufferDC, btImageCoords.x, btImageCoords.y, m_ButtonWidth, m_ButtonHeight, 0, m_ButtonHeight * 2, m_ButtonWidth, m_ButtonHeight
            End If
            
            'Release the button image DC, as it's no longer required.  (It will auto-generate a new DC the next
            ' time we need to render it to the underlying button.)
            m_ButtonImages.FreeFromDC
            
        End If
        
    End If
    
    'Paint the final result to the screen, as relevant
    ucSupport.RequestRepaint raiseImmediateDrawEvent
    
End Sub

'Before this control does any painting, we need to retrieve relevant colors from PD's primary theming class.  Note that this
' step must also be called if/when PD's visual theme settings change.
Private Sub UpdateColorList()
    With m_Colors
        .LoadThemeColor PDTB_Background, "Background", IDE_WHITE
        .LoadThemeColor PDTB_ButtonFill, "ButtonFill", IDE_WHITE
        .LoadThemeColor PDTB_Border, "Border", IDE_WHITE
    End With
End Sub

'External functions can call this to request a redraw.  This is helpful for live-updating theme settings, as in the Preferences dialog.
Public Sub UpdateAgainstCurrentTheme(Optional ByVal hostFormhWnd As Long = 0)
    If ucSupport.ThemeUpdateRequired Then
        UpdateColorList
        If MainModule.IsProgramRunning() Then NavKey.NotifyControlLoad Me, hostFormhWnd
        If MainModule.IsProgramRunning() Then ucSupport.UpdateAgainstThemeAndLanguage
    End If
End Sub

'By design, PD prefers to not use design-time tooltips.  Apply tooltips at run-time, using this function.
' (IMPORTANT NOTE: translations are handled automatically.  Always pass the original English text!)
Public Sub AssignTooltip(ByVal newTooltip As String, Optional ByVal newTooltipTitle As String, Optional ByVal newTooltipIcon As TT_ICON_TYPE = TTI_NONE)
    ucSupport.AssignTooltip UserControl.ContainerHwnd, newTooltip, newTooltipTitle, newTooltipIcon
End Sub
