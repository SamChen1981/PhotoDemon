VERSION 5.00
Begin VB.UserControl pdTitle 
   Appearance      =   0  'Flat
   BackColor       =   &H00FFFFFF&
   ClientHeight    =   450
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   3930
   DrawStyle       =   5  'Transparent
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   9.75
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   HasDC           =   0   'False
   ScaleHeight     =   30
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   262
   ToolboxBitmap   =   "pdTitle.ctx":0000
End
Attribute VB_Name = "pdTitle"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Collapsible Title Label+Button control
'Copyright 2014-2018 by Tanner Helland
'Created: 19/October/14
'Last updated: 22/February/18
'Last update: new "Draggable" property will render a left-side gripper on the titlebar
'
'In a surprise to precisely no one, PhotoDemon has some unique needs when it comes to user controls - needs that
' the intrinsic VB controls can't handle.  These range from the obnoxious (lack of an "autosize" property for
' anything but labels) to the critical (no Unicode support).
'
'As such, I've created many of my own UCs for the program.  All are owner-drawn, with the goal of maintaining
' visual fidelity across the program, while also enabling key features like Unicode support.
'
'A few notes on this "title" control, specifically:
'
' 1) Captioning is (mostly) handled by the pdCaption class, so autosizing of overlong text is supported.
' 2) High DPI settings are handled automatically.
' 3) A hand cursor is automatically applied, and clicks are returned via the Click event.
' 4) Coloration is automatically handled by PD's internal theming engine.
' 5) This title control is meant to be used above collapsible UI panels.  It auto-toggles between a "true" and
'     "false" state, and this state is returned directly inside the Click() event.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'This control really only needs one event raised - Click.  However, a few other events are raised for
' special situations where this control needs to do more than just open/close a corresponding panel.
Public Event Click(ByVal newState As Boolean)
Public Event MouseDownCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal timeStamp As Long)
Public Event MouseDrag(ByVal xChange As Long, ByVal yChange As Long)
Public Event MouseUpCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal clickEventAlsoFiring As Boolean, ByVal timeStamp As Long)

'Because VB focus events are wonky, especially when we use CreateWindow within a UC, this control raises its own
' specialized focus events.  If you need to track focus, use these instead of the default VB functions.
Public Event GotFocusAPI()
Public Event LostFocusAPI()

'Rect where the caption is rendered.  This is calculated by UpdateControlLayout, and it needs to be revisited if the
' caption changes, or the control size changes.
Private m_CaptionRect As RECT

'Current title state (TRUE when arrow is pointing down, e.g. the associated container is "open")
Private m_TitleState As Boolean

'Some titlebars support drag-to-resize behavior for their associated container.  This is accessible via the
' "Draggable" property
Private m_Draggable As Boolean
Private Const GRIPPER_PADDING As Long = 12

'If this titlebar supports drag-to-resize behavior, we need to raise corresponding mouse events so our
' parent control can handle the resize.  On _MouseDown, the initial mouse position is cached; subsequent
' _MouseMove events will compare against these coordinates to determine drag distance.
Private m_InitMouseX As Single, m_InitMouseY As Single

'2D painting support classes
Private m_Painter As pd2DPainter

'User control support class.  Historically, many classes (and associated subclassers) were required by each user control,
' but I've since attempted to wrap these into a single master control support class.
Private WithEvents ucSupport As pdUCSupport
Attribute ucSupport.VB_VarHelpID = -1

'Local list of themable colors.  This list includes all potential colors used by this class, regardless of state change
' or internal control settings.  The list is updated by calling the UpdateColorList function.
' (Note also that this list does not include variants, e.g. "BorderColor" vs "BorderColor_Hovered".  Variant values are
'  automatically calculated by the color management class, and they are retrieved by passing boolean modifiers to that
'  class, rather than treating every imaginable variant as a separate constant.)
Private Enum PDTITLE_COLOR_LIST
    [_First] = 0
    PDT_Background = 0
    PDT_Caption = 1
    PDT_Arrow = 2
    PDT_Border = 3
    [_Last] = 3
    [_Count] = 4
End Enum

'Color retrieval and storage is handled by a dedicated class; this allows us to optimize theme interactions,
' without worrying about the details locally.
Private m_Colors As pdThemeColors

Public Function GetControlType() As PD_ControlType
    GetControlType = pdct_Title
End Function

Public Function GetControlName() As String
    GetControlName = UserControl.Extender.Name
End Function

'Caption is handled just like the common control label's caption property.  It is valid at design-time, and any translation,
' if present, will not be processed until run-time.
' IMPORTANT NOTE: only the ENGLISH caption is returned.  I don't have a reason for returning a translated caption (if any),
'                  but I can revisit in the future if it ever becomes relevant.
Public Property Get Caption() As String
Attribute Caption.VB_UserMemId = -518
    Caption = ucSupport.GetCaptionText
End Property

Public Property Let Caption(ByRef newCaption As String)
    
    ucSupport.SetCaptionText newCaption
    PropertyChanged "Caption"
    
    'Access keys must be handled manually.
    Dim ampPos As Long
    ampPos = InStr(1, newCaption, "&", vbBinaryCompare)
    
    If (ampPos > 0) And (ampPos < Len(newCaption)) Then
    
        'Get the character immediately following the ampersand, and dynamically assign it
        Dim accessKeyChar As String
        accessKeyChar = Mid$(newCaption, ampPos + 1, 1)
        UserControl.AccessKeys = accessKeyChar
    
    Else
        UserControl.AccessKeys = vbNullString
    End If
    
End Property

'Changing the Draggable property does not currently initiate a redraw event; it's assumed that this property
' won't be changed at run-time (although there is no technical reason that you couldn't change it).
Public Property Get Draggable() As Boolean
    Draggable = m_Draggable
End Property

Public Property Let Draggable(ByVal newSetting As Boolean)
    m_Draggable = newSetting
End Property

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
Attribute Enabled.VB_UserMemId = -514
    Enabled = UserControl.Enabled
End Property

Public Property Let Enabled(ByVal newValue As Boolean)
    UserControl.Enabled = newValue
    If pdMain.IsProgramRunning() Then RedrawBackBuffer
    PropertyChanged "Enabled"
End Property

Public Property Get FontBold() As Boolean
    FontBold = ucSupport.GetCaptionFontBold
End Property

Public Property Let FontBold(ByVal newValue As Boolean)
    ucSupport.SetCaptionFontBold newValue
    PropertyChanged "FontBold"
End Property

Public Property Get FontSize() As Single
    FontSize = ucSupport.GetCaptionFontSize
End Property

Public Property Let FontSize(ByVal newSize As Single)
    ucSupport.SetCaptionFontSize newSize
    PropertyChanged "FontSize"
End Property

'hWnds aren't exposed by default
Public Property Get hWnd() As Long
Attribute hWnd.VB_UserMemId = -515
    hWnd = UserControl.hWnd
End Property

'State is toggled on each click.  TRUE means the accompanying panel should be OPEN.
Public Property Get Value() As Boolean
Attribute Value.VB_UserMemId = 0
    Value = m_TitleState
End Property

Public Property Let Value(ByVal newState As Boolean)
    If (newState <> m_TitleState) Then
        m_TitleState = newState
        RedrawBackBuffer
        RaiseEvent Click(newState)
        PropertyChanged "Value"
    End If
End Property

'To support high-DPI settings properly, we expose some specialized move+size functions
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

Public Sub SetPositionAndSize(ByVal newLeft As Long, ByVal newTop As Long, ByVal newWidth As Long, ByVal newHeight As Long)
    ucSupport.RequestFullMove newLeft, newTop, newWidth, newHeight, True
End Sub

Private Sub ucSupport_ClickCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)

    If Me.Enabled And ((Button And pdLeftButton) <> 0) Then
    
        'Toggle title state and redraw
        m_TitleState = Not m_TitleState
        
        'Note that drawing flags are handled by MouseDown/Up.  Click() is only used for raising a matching Click() event.
        RaiseEvent Click(m_TitleState)
        RedrawBackBuffer
        
    End If
    
End Sub

'A few key events are also handled
Private Sub ucSupport_KeyDownCustom(ByVal Shift As ShiftConstants, ByVal vkCode As Long, markEventHandled As Boolean)
    
    markEventHandled = False
    
    'When space is released, redraw the button to match
    If (vkCode = VK_SPACE) Then

        If Me.Enabled Then
            m_TitleState = Not m_TitleState
            RedrawBackBuffer
            RaiseEvent Click(m_TitleState)
            markEventHandled = True
        End If
        
    End If

End Sub

Private Sub ucSupport_KeyDownSystem(ByVal Shift As ShiftConstants, ByVal whichSysKey As PD_NavigationKey, markEventHandled As Boolean)
    
    'Enter/Esc get reported directly to the system key handler.  Note that we track the return, because TRUE
    ' means the key was successfully forwarded to the relevant handler.  (If FALSE is returned, no control
    ' accepted the keypress, meaning we should forward the event down the line.)
    markEventHandled = NavKey.NotifyNavKeypress(Me, whichSysKey, Shift)
    
End Sub

Private Sub ucSupport_MouseDownCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal timeStamp As Long)
    
    'Cache the current mouse position.  Importantly, note that we must translate these coordinates to
    ' *screen* coordinates, as it's possible our parent control will move our window as a result of
    ' this drag (which in turn causes mouse coords to go berserk).
    If (Not g_WindowManager Is Nothing) Then
        
        Dim tmpPoint As POINTAPI
        tmpPoint.x = x
        tmpPoint.y = y
        g_WindowManager.GetClientToScreen Me.hWnd, tmpPoint
        
        m_InitMouseX = tmpPoint.x
        m_InitMouseY = tmpPoint.y
        
        ucSupport.RequestAutoDropMouseMessages False
        
    End If
    
    RaiseEvent MouseDownCustom(Button, Shift, x, y, timeStamp)
    
End Sub

Private Sub ucSupport_MouseEnter(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    
    'Draggable titlebars display a hybrid hand+arrow cursor
    If m_Draggable Then
        ucSupport.RequestCursor_Resource "HAND-AND-RESIZE"
    Else
        ucSupport.RequestCursor IDC_HAND
    End If
    
    RedrawBackBuffer
    
End Sub

'When the mouse leaves the UC, we must repaint the button (as it's no longer hovered)
Private Sub ucSupport_MouseLeave(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
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

Private Sub ucSupport_MouseMoveCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal timeStamp As Long)

    'If the left mouse button is pressed, relay any changes in position to our parent control.
    If (Button And pdLeftButton <> 0) And (Not g_WindowManager Is Nothing) Then
        
        'Convert the mouse coord to screen coordinates
        Dim tmpPoint As POINTAPI
        tmpPoint.x = x
        tmpPoint.y = y
        g_WindowManager.GetClientToScreen Me.hWnd, tmpPoint
        
        'Relay the *difference* between the current coords and initial coords to our parent control
        RaiseEvent MouseDrag(tmpPoint.x - m_InitMouseX, tmpPoint.y - m_InitMouseY)
        
    End If

End Sub

Private Sub ucSupport_MouseUpCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal clickEventAlsoFiring As Boolean, ByVal timeStamp As Long)
    ucSupport.RequestAutoDropMouseMessages True
    RaiseEvent MouseUpCustom(Button, Shift, x, y, clickEventAlsoFiring, timeStamp)
End Sub

Private Sub ucSupport_RepaintRequired(ByVal updateLayoutToo As Boolean)
    If updateLayoutToo Then UpdateControlLayout Else RedrawBackBuffer
End Sub

Private Sub UserControl_AccessKeyPress(KeyAscii As Integer)
    m_TitleState = Not m_TitleState
    RaiseEvent Click(m_TitleState)
End Sub

Private Sub UserControl_Initialize()
    
    'Initialize a master user control support class
    Set ucSupport = New pdUCSupport
    ucSupport.RegisterControl UserControl.hWnd, True
    
    'Request any control-specific functionality
    ucSupport.RequestExtraFunctionality True, True
    ucSupport.SpecifyRequiredKeys VK_SPACE
    ucSupport.RequestCaptionSupport
    ucSupport.SetCaptionAutomaticPainting False
    
    'Prep painting classes
    Drawing2D.QuickCreatePainter m_Painter
    
    'Prep the color manager and load default colors
    Set m_Colors = New pdThemeColors
    Dim colorCount As PDTITLE_COLOR_LIST: colorCount = [_Count]
    m_Colors.InitializeColorList "PDTitle", colorCount
    If Not pdMain.IsProgramRunning() Then UpdateColorList
      
End Sub

'Set default properties
Private Sub UserControl_InitProperties()
    Caption = vbNullString
    Draggable = False
    FontBold = False
    FontSize = 10
    Value = True
End Sub

'At run-time, painting is handled by PD's pdWindowPainter class.  In the IDE, however, we must rely on VB's internal paint event.
Private Sub UserControl_Paint()
    ucSupport.RequestIDERepaint UserControl.hDC
End Sub

Private Sub UserControl_ReadProperties(PropBag As PropertyBag)
    With PropBag
        Caption = .ReadProperty("Caption", vbNullString)
        Draggable = .ReadProperty("Draggable", False)
        FontBold = .ReadProperty("FontBold", False)
        FontSize = .ReadProperty("FontSize", 10)
        m_TitleState = .ReadProperty("Value", True)
    End With
End Sub

Private Sub UserControl_Resize()
    If (Not pdMain.IsProgramRunning()) Then ucSupport.NotifyIDEResize UserControl.Width, UserControl.Height
End Sub

Private Sub UserControl_WriteProperties(PropBag As PropertyBag)
    With PropBag
        .WriteProperty "Caption", ucSupport.GetCaptionText, vbNullString
        .WriteProperty "Draggable", m_Draggable, False
        .WriteProperty "FontBold", ucSupport.GetCaptionFontBold, False
        .WriteProperty "FontSize", ucSupport.GetCaptionFontSize, 10
        .WriteProperty "Value", m_TitleState, True
    End With
End Sub

'Because this control automatically forces all internal buttons to identical sizes, we have to recalculate a number
' of internal sizing metrics whenever the control size changes.
Private Sub UpdateControlLayout()

    'Retrieve DPI-aware control dimensions from the support class
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    Const hTextPadding As Long = 2&, vTextPadding As Long = 2&
    
    'Next, determine the positioning of the caption, if present.  (ucSupport.GetCaptionBottom tells us where the
    ' caption text ends vertically.)
    If ucSupport.IsCaptionActive Then
    
        'Normally, we would rely on the built-in caption support of the ucSupport class.  However, this control
        ' behaves like a label by attempting to fit its caption into the available space as neatly as possible.
        ' As such, the built-in ucSupport class will have already auto-sized its font based on the *previous*
        ' control size.  Because we are inside the UpdateControlLayout sub, we know that the control's size
        ' has changed, which means we need to perform a fresh size calculation.
        
        'As such, start with a default caption instance.
        Dim tmpFont As pdFont
        Set tmpFont = Fonts.GetMatchingUIFont(Me.FontSize, Me.FontBold)
        
        'In this control, we auto-size the control's height according to the control's current font size.
        ' In turn, the control's font size may be automatically shrunk to fit the control's available width.
        
        '(I know, it's a bit confusing.)
        
        'Let's start by determining how much horizontal space is available for the caption.
        Dim maxCaptionWidth As Long
        maxCaptionWidth = bWidth - (FixDPI(hTextPadding) * 2) - bHeight
        
        'If the control is draggable, we need to account for some extra left-side space to render a gripper
        If m_Draggable Then maxCaptionWidth = maxCaptionWidth - Interface.FixDPI(GRIPPER_PADDING)
        
        'Next, determine if our current caption + font-size combination fits within the available space.
        Dim fontWidth As Long
        fontWidth = tmpFont.GetWidthOfString(Me.Caption)
        
        'If our current caption + font-size fits in the available space, great!  Use our current font height
        ' to auto-size this control accordingly.
        If (fontWidth <= maxCaptionWidth) Then
        
            If (tmpFont.GetHeightOfString(Me.Caption) + FixDPI(vTextPadding) * 2 <> bHeight) Then
                bHeight = tmpFont.GetHeightOfString(Me.Caption) + FixDPI(vTextPadding) * 2
                ucSupport.RequestNewSize bWidth, bHeight, False
            End If
            
        'If our current caption + font-size does *not* fit in the available space, we need to figure out what
        ' size *does* fit.
        Else
        
            Dim tmpFontSize As Single
            tmpFontSize = Fonts.FindFontSizeSingleLine(Me.Caption, maxCaptionWidth, Me.FontSize, Me.FontBold, , , True)
            
            'Retrieve a new font object at the specified size.
            Set tmpFont = Fonts.GetMatchingUIFont(tmpFontSize, Me.FontBold)
            
            'Use that font's height to calculate a new height for this control
            If (tmpFont.GetHeightOfString(Me.Caption) + FixDPI(vTextPadding) * 2 <> bHeight) Then
                bHeight = tmpFont.GetHeightOfString(Me.Caption) + FixDPI(vTextPadding) * 2
                ucSupport.RequestNewSize bWidth, bHeight, False
            End If
            
        End If
        
        'The control and backbuffer are now guaranteed to be the proper size.  Update our internal trackers.
        bWidth = ucSupport.GetBackBufferWidth
        bHeight = ucSupport.GetBackBufferHeight
    
        'For caption rendering purposes, we need to determine a target rectangle for the caption itself.  The ucSupport class
        ' will automatically fit the caption within this area, regardless of the currently selected font size.
        With m_CaptionRect
            .Left = FixDPI(hTextPadding)
            If m_Draggable Then .Left = .Left + Interface.FixDPI(GRIPPER_PADDING)
            .Top = FixDPI(vTextPadding)
            .Bottom = bHeight - FixDPI(vTextPadding)
            
            'The right measurement is the only complicated one, as it requires padding so we have room to render the drop-down arrow.
            .Right = bWidth - FixDPI(hTextPadding) * 2 - bHeight
            If m_Draggable Then .Right = .Right - Interface.FixDPI(GRIPPER_PADDING)
            If (.Right < .Left) Then .Right = .Left + 1
            
            'Notify the caption renderer of this new caption position, which it will use to automatically adjust its font, as necessary
            ucSupport.SetCaptionCustomPosition .Left, .Top, .Right - .Left, .Bottom - .Top
        End With
        
    End If
        
    'No other special preparation is required for this control, so proceed with recreating the back buffer
    RedrawBackBuffer
            
End Sub

'Before this control does any painting, we need to retrieve relevant colors from PD's primary theming class.  Note that this
' step must also be called if/when PD's visual theme settings change.
Private Sub UpdateColorList()
    With m_Colors
        .LoadThemeColor PDT_Background, "Background", IDE_WHITE
        .LoadThemeColor PDT_Caption, "Caption", IDE_GRAY
        .LoadThemeColor PDT_Arrow, "Arrow", IDE_BLUE
        .LoadThemeColor PDT_Border, "Border", IDE_BLUE
    End With
End Sub

'External functions can call this to request a redraw.  This is helpful for live-updating theme settings, as in the Preferences dialog.
Public Sub UpdateAgainstCurrentTheme(Optional ByVal hostFormhWnd As Long = 0)
    If ucSupport.ThemeUpdateRequired Then
        UpdateColorList
        If pdMain.IsProgramRunning() Then NavKey.NotifyControlLoad Me, hostFormhWnd
        If pdMain.IsProgramRunning() Then ucSupport.UpdateAgainstThemeAndLanguage
    End If
End Sub

'Use this function to completely redraw the back buffer from scratch.  Note that this is computationally expensive compared to just flipping the
' existing buffer to the screen, so only redraw the backbuffer if the control state has somehow changed.
Private Sub RedrawBackBuffer()
    
    Dim ctlFillColor As Long
    ctlFillColor = m_Colors.RetrieveColor(PDT_Background, Me.Enabled, , ucSupport.IsMouseInside)
    
    'Request the back buffer DC, and ask the support module to erase any existing rendering for us.
    Dim bufferDC As Long
    bufferDC = ucSupport.GetBackBufferDC(True, ctlFillColor)
    If (bufferDC = 0) Then Exit Sub
    
    Dim bWidth As Long, bHeight As Long
    bWidth = ucSupport.GetBackBufferWidth
    bHeight = ucSupport.GetBackBufferHeight
    
    Dim txtColor As Long, arrowColor As Long, ctlTopLineColor As Long
    arrowColor = m_Colors.RetrieveColor(PDT_Arrow, Me.Enabled, , ucSupport.IsMouseInside)
    ctlTopLineColor = m_Colors.RetrieveColor(PDT_Border, Me.Enabled, ucSupport.DoIHaveFocus, ucSupport.IsMouseInside)
    txtColor = m_Colors.RetrieveColor(PDT_Caption, Me.Enabled, , ucSupport.IsMouseInside)
    
    If ucSupport.IsCaptionActive Then
        ucSupport.SetCaptionCustomColor txtColor
        ucSupport.PaintCaptionManually
    End If
    
    If pdMain.IsProgramRunning() Then
        
        Dim cSurface As pd2DSurface, cBrush As pd2DBrush, cPen As pd2DPen
        Drawing2D.QuickCreateSurfaceFromDC cSurface, bufferDC, True
        
        'If this control instance is "draggable", let's render a gripper on its left-hand side
        If m_Draggable Then
            
            'Turn off antialiasing prior to drawing the gripper
            cSurface.SetSurfaceAntialiasing P2_AA_None
            
            'Use the same arrow color, but at a reduced opacity
            Drawing2D.QuickCreateSolidBrush cBrush, arrowColor, 70!
            
            'Boxes are 2x2 logical pixels, with 2-px padding between them
            Dim xStep As Long, yStep As Long, boxSize As Long
            xStep = Interface.FixDPI(4)
            yStep = Interface.FixDPI(4)
            boxSize = Interface.FixDPI(2)
            
            Dim x As Long, y As Long
            For x = 0 To xStep Step xStep
            For y = yStep To bHeight - yStep Step yStep
                m_Painter.FillRectangleI cSurface, cBrush, x, y, boxSize, boxSize
            Next y
            Next x
            
            'Restore antialiasing so that subsequent steps look okay
            cSurface.SetSurfaceAntialiasing P2_AA_HighQuality
            
        End If
    
        'Next, paint the drop-down arrow.  To simplify calculations, we first calculate a boundary rect.
        Dim arrowRect As RectF
        arrowRect.Left = bWidth - bHeight - FixDPI(2)
        arrowRect.Top = 1
        arrowRect.Height = bHeight - 2
        arrowRect.Width = bHeight - 2
        
        Dim arrowPt1 As PointFloat, arrowPt2 As PointFloat, arrowPt3 As PointFloat
                    
        'The orientation of the arrow varies depending on open/close state.
        
        'Corresponding panel is open, so arrow points down
        If m_TitleState Then
        
            arrowPt1.x = arrowRect.Left + FixDPIFloat(4)
            arrowPt1.y = arrowRect.Top + (arrowRect.Height / 2) - FixDPIFloat(2)
            
            arrowPt3.x = (arrowRect.Left + arrowRect.Width) - FixDPIFloat(4)
            arrowPt3.y = arrowPt1.y
            
            arrowPt2.x = arrowPt1.x + (arrowPt3.x - arrowPt1.x) / 2
            arrowPt2.y = arrowPt1.y + FixDPIFloat(3)
            
        'Corresponding panel is closed, so arrow points left
        Else
        
            arrowPt1.x = arrowRect.Left + (arrowRect.Width / 2) + FixDPIFloat(2)
            arrowPt1.y = arrowRect.Top + FixDPIFloat(4)
        
            arrowPt3.x = arrowPt1.x
            arrowPt3.y = (arrowRect.Top + arrowRect.Height) - FixDPIFloat(4)
        
            arrowPt2.x = arrowPt1.x - FixDPIFloat(3)
            arrowPt2.y = arrowPt1.y + (arrowPt3.y - arrowPt1.y) / 2
        
        End If
        
        'Draw the drop-down arrow
        Drawing2D.QuickCreateSolidPen cPen, 2#, arrowColor, 100#, P2_LJ_Round, P2_LC_Round
        m_Painter.DrawLineF_FromPtF cSurface, cPen, arrowPt1, arrowPt2
        m_Painter.DrawLineF_FromPtF cSurface, cPen, arrowPt2, arrowPt3
        
        'Finally, frame the control.  At present, this consists of two gradient lines - one across the top, the other down the right side.
        Dim ctlRect As RectF
        With ctlRect
            .Left = 0#
            .Top = 0#
            .Width = bWidth
            .Height = bHeight
        End With
        Drawing2D.QuickCreateTwoColorGradientBrush cBrush, ctlRect, ctlFillColor, ctlTopLineColor
        cPen.SetPenWidth 1#
        cPen.CreatePenFromBrush cBrush
        m_Painter.DrawLineF cSurface, cPen, ctlRect.Left, ctlRect.Top, ctlRect.Width, ctlRect.Top
        
        'For convenience, you can uncomment this line to also paint the bottom boundary of the control.
        ' I've used this while trying to perfect rendering layouts.
        'm_Painter.DrawLineF cSurface, cPen, ctlRect.Left, ctlRect.Top + ctlRect.Height - 1, ctlRect.Width, ctlRect.Top + ctlRect.Height - 1
        
        ctlRect.Top = ctlRect.Top - 1
        ctlRect.Width = ctlRect.Width - 1
        Drawing2D.QuickCreateTwoColorGradientBrush cBrush, ctlRect, ctlFillColor, ctlTopLineColor, , , , 270#
        cPen.CreatePenFromBrush cBrush
        m_Painter.DrawLineF cSurface, cPen, ctlRect.Width, ctlRect.Top, ctlRect.Width, ctlRect.Height
        
        Set cSurface = Nothing: Set cBrush = Nothing: Set cPen = Nothing
        
    End If
    
    'Paint the final result to the screen, as relevant
    ucSupport.RequestRepaint
    
End Sub

'By design, PD prefers to not use design-time tooltips.  Apply tooltips at run-time, using this function.
' (IMPORTANT NOTE: translations are handled automatically.  Always pass the original English text!)
Public Sub AssignTooltip(ByRef newTooltip As String, Optional ByRef newTooltipTitle As String = vbNullString, Optional ByVal raiseTipsImmediately As Boolean = False)
    ucSupport.AssignTooltip UserControl.ContainerHwnd, newTooltip, newTooltipTitle, raiseTipsImmediately
End Sub
