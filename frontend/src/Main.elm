port module Main exposing (Msg(..), main, update, view)

import Bootstrap.Accordion as Accordion
import Bootstrap.Alert as Alert
import Bootstrap.Button as Button
import Bootstrap.ButtonGroup as ButtonGroup
import Bootstrap.Card.Block as Block
import Bootstrap.Form as Form
import Bootstrap.Form.Checkbox as Checkbox
import Bootstrap.Form.Fieldset as Fieldset
import Bootstrap.Form.Input as Input
import Bootstrap.Form.Radio as Radio
import Bootstrap.Form.Select as Select
import Bootstrap.Form.Textarea as Textarea
import Bootstrap.Grid as Grid
import Bootstrap.Grid.Col as Col
import Bootstrap.ListGroup as ListGroup
import Bootstrap.Modal as Modal
import Bootstrap.Navbar as Navbar
import Browser
import Color exposing (Color)
import Html exposing (Html, button, div, h1, h2, h3, h4, img, li, span, text, ul)
import Html.Attributes exposing (class, height, href, placeholder, src, style, type_, value, width)
import Html.Events exposing (onClick, onInput)
import Http
import Json.Decode
import Json.Decode.Pipeline exposing (hardcoded, optional, required)
import Json.Encode
import List.Extra as ListExtra
import Material.Icons.Image exposing (edit)
import Sample exposing (Sample, encodeSample, renderSample, sampleDecoder)
import Task
import Time
import Url.Builder as Url


main =
    Browser.document
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }



-- Model


type alias Response =
    { success : Bool
    , error : String
    , id : String
    }


type alias ResponseError =
    { success : Bool
    , error : String
    }


type alias ResponseSuccess =
    { success : Bool
    , data :
        { id : String
        }
    }


type alias Device =
    { id : String
    , config : DeviceConfig
    , state : DeviceState
    }


type alias DeviceConfig =
    { description : String
    }


type alias DeviceState =
    { ios : List Sample
    }


type alias Devices =
    { devices : List Device
    , dirty : Bool
    }


type alias DeviceEdits =
    { device : Maybe Device
    , visibility : Modal.Visibility
    }


type alias GwConfigWifi =
    { wifiSSID : String
    , wifiPass : String
    }


gwConfigWifiInit : GwConfigWifi
gwConfigWifiInit =
    { wifiSSID = ""
    , wifiPass = ""
    }


encodeGwConfigWifi : GwConfigWifi -> Json.Encode.Value
encodeGwConfigWifi config =
    Json.Encode.object
        [ ( "cmd", Json.Encode.string <| "configureWifi" )
        , ( "wifiSSID", Json.Encode.string <| config.wifiSSID )
        , ( "wifiPass", Json.Encode.string <| config.wifiPass )
        ]


type alias GwConfigTimer =
    { fireDuration : Int
    , fireTime : String
    }


gwConfigTimerInit : GwConfigTimer
gwConfigTimerInit =
    { fireDuration = 0
    , fireTime = "00:00"
    }


encodeGwConfigTimer : GwConfigTimer -> Json.Encode.Value
encodeGwConfigTimer config =
    Json.Encode.object
        [ ( "cmd", Json.Encode.string <| "configureTimer" )
        , ( "fireDuration", Json.Encode.int <| config.fireDuration )
        , ( "fireTime", Json.Encode.string <| config.fireTime )
        ]


type alias Model =
    { navbarState : Navbar.State
    , accordionState : Accordion.State
    , devices : Devices
    , deviceEdits : DeviceEdits
    , tab : Tab
    , gwState : GwState
    , gwConfigWifi : GwConfigWifi
    , gwConfigTimer : GwConfigTimer
    , timeZone : Time.Zone
    }


type alias PortCmd =
    { cmd : String
    }


encodePortCmd : PortCmd -> Json.Encode.Value
encodePortCmd cmd =
    Json.Encode.object
        [ ( "cmd", Json.Encode.string <| cmd.cmd ) ]


type Tab
    = TabDevices
    | TabConfigure


type Msg
    = Increment
    | Decrement
    | NavbarMsg Navbar.State
    | AccordionMsg Accordion.State
    | Tick Time.Posix
    | UpdateDevices (Result Http.Error (List Device))
    | DeviceConfigPosted (Result Http.Error Response)
    | DeviceDelete (Result Http.Error Response)
    | EditDevice String
    | EditDeviceClose
    | EditDeviceSave
    | EditDeviceDelete String
    | EditDeviceChangeDescription String
    | ProcessPortValue (Result Json.Decode.Error PortValue)
    | SetTab Tab
    | BLEScan
    | BLEDisconnect
    | SetGwWifiSSID String
    | SetGwWifiPass String
    | GwWriteWifi
    | GwWriteTimer
    | GwFireTimer
    | GwSetTimerFireDuration String
    | GwSetTimerFireTime String
    | GotZone Time.Zone



-- ports


port portIn : (Json.Decode.Value -> msg) -> Sub msg


port portOut : Json.Encode.Value -> Cmd msg



-- Subscriptions


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Navbar.subscriptions model.navbarState NavbarMsg
        , Accordion.subscriptions model.accordionState AccordionMsg
        , Time.every 1000 Tick
        , portIn (portValueDecoder >> ProcessPortValue)
        ]



-- The navbar needs to know the initial window size, so the inital state for a navbar requires a command to be run by the Elm runtime
-- Init


init : () -> ( Model, Cmd Msg )
init model =
    let
        ( navbarState, navbarCmd ) =
            Navbar.initialState NavbarMsg
    in
    ( { navbarState = navbarState
      , accordionState = Accordion.initialState
      , devices = { devices = [], dirty = False }
      , deviceEdits = { device = Nothing, visibility = Modal.hidden }
      , tab = TabDevices
      , gwState = gwStateInit
      , gwConfigWifi = gwConfigWifiInit
      , gwConfigTimer = gwConfigTimerInit
      , timeZone = Time.utc
      }
    , Cmd.batch [ navbarCmd, Task.perform GotZone Time.here ]
    )



-- Update


urlDevices =
    Url.absolute [ "v1", "devices" ] []


responseDecoder : Json.Decode.Decoder Response
responseDecoder =
    Json.Decode.succeed Response
        |> required "success" Json.Decode.bool
        |> optional "error" Json.Decode.string ""
        |> optional "id" Json.Decode.string ""


samplesDecoder : Json.Decode.Decoder (List Sample)
samplesDecoder =
    Json.Decode.list sampleDecoder


deviceConfigDecoder : Json.Decode.Decoder DeviceConfig
deviceConfigDecoder =
    Json.Decode.map DeviceConfig
        (Json.Decode.field "description" Json.Decode.string)


deviceStateDecoder : Json.Decode.Decoder DeviceState
deviceStateDecoder =
    Json.Decode.map DeviceState
        (Json.Decode.field "ios" samplesDecoder)


deviceDecoder : Json.Decode.Decoder Device
deviceDecoder =
    Json.Decode.map3 Device
        (Json.Decode.field "id" Json.Decode.string)
        (Json.Decode.field "config" deviceConfigDecoder)
        (Json.Decode.field "state" deviceStateDecoder)


devicesDecoder : Json.Decode.Decoder (List Device)
devicesDecoder =
    Json.Decode.list deviceDecoder


apiGetDevices : Cmd Msg
apiGetDevices =
    Http.get
        { url = urlDevices
        , expect = Http.expectJson UpdateDevices devicesDecoder
        }


deviceConfigEncoder : DeviceConfig -> Json.Encode.Value
deviceConfigEncoder deviceConfig =
    Json.Encode.object
        [ ( "description", Json.Encode.string deviceConfig.description )
        ]


apiPostDeviceConfig : String -> DeviceConfig -> Cmd Msg
apiPostDeviceConfig id config =
    let
        body =
            config |> deviceConfigEncoder |> Http.jsonBody

        url =
            Url.absolute [ "v1", "devices", id, "config" ] []
    in
    Http.post
        { url = url
        , body = body
        , expect = Http.expectJson DeviceConfigPosted responseDecoder
        }


apiPostDeviceDelete : String -> Cmd Msg
apiPostDeviceDelete id =
    let
        url =
            Url.absolute [ "v1", "devices", id ] []
    in
    Http.request
        { method = "DELETE"
        , headers = []
        , url = url
        , body = Http.emptyBody
        , expect = Http.expectJson DeviceDelete responseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


findDevice : List Device -> String -> Maybe Device
findDevice devices id =
    ListExtra.find (\d -> d.id == id) devices


updateDevice : List Device -> Maybe Device -> List Device
updateDevice devices device =
    case device of
        Nothing ->
            devices

        Just deviceUpdate ->
            let
                index =
                    ListExtra.findIndex (\d -> d.id == deviceUpdate.id) devices

                devicesModified =
                    case index of
                        Nothing ->
                            List.append devices [ deviceUpdate ]

                        Just i ->
                            ListExtra.setAt i deviceUpdate devices
            in
            devicesModified


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Increment ->
            ( model, Cmd.none )

        Decrement ->
            ( model, Cmd.none )

        NavbarMsg state ->
            ( { model | navbarState = state }, Cmd.none )

        AccordionMsg state ->
            ( { model | accordionState = state }, Cmd.none )

        Tick newTime ->
            ( model, apiGetDevices )

        UpdateDevices result ->
            case model.devices.dirty of
                True ->
                    ( model, Cmd.none )

                False ->
                    case result of
                        Ok devicesUpdate ->
                            ( { model | devices = { devices = devicesUpdate, dirty = False } }, Cmd.none )

                        Err err ->
                            ( model, Cmd.none )

        DeviceConfigPosted result ->
            let
                devices =
                    model.devices

                newDevices =
                    { devices | dirty = False }

                newModel =
                    { model | devices = newDevices }
            in
            case result of
                -- fixme show error dialog
                Ok string ->
                    ( newModel, Cmd.none )

                Err err ->
                    ( newModel, Cmd.none )

        DeviceDelete result ->
            let
                devices =
                    model.devices

                newDevices =
                    { devices | dirty = False }

                newModel =
                    { model | devices = newDevices }
            in
            case result of
                -- fixme show error dialog
                Ok resp ->
                    let
                        devicesRm =
                            List.filter (\d -> d.id /= resp.id) newDevices.devices

                        newNewDevices =
                            { newDevices | devices = devicesRm }
                    in
                    ( { newModel | devices = newNewDevices }, Cmd.none )

                Err err ->
                    ( newModel, Cmd.none )

        EditDevice id ->
            ( { model
                | deviceEdits = { visibility = Modal.shown, device = findDevice model.devices.devices id }
              }
            , Cmd.none
            )

        EditDeviceClose ->
            ( { model
                | deviceEdits =
                    { visibility = Modal.hidden
                    , device = Nothing
                    }
              }
            , Cmd.none
            )

        EditDeviceSave ->
            ( { model
                | devices =
                    { devices = updateDevice model.devices.devices model.deviceEdits.device
                    , dirty = True
                    }
                , deviceEdits = { device = model.deviceEdits.device, visibility = Modal.hidden }
              }
            , case model.deviceEdits.device of
                Nothing ->
                    Cmd.none

                Just dev ->
                    apiPostDeviceConfig dev.id dev.config
            )

        EditDeviceDelete id ->
            let
                deviceEditsIn =
                    model.deviceEdits

                deviceEdits =
                    { deviceEditsIn | visibility = Modal.hidden }
            in
            ( { model | deviceEdits = deviceEdits }, apiPostDeviceDelete id )

        EditDeviceChangeDescription desc ->
            case model.deviceEdits.device of
                Nothing ->
                    ( model, Cmd.none )

                Just device ->
                    let
                        deviceConfig =
                            device.config

                        newDeviceConfig =
                            { deviceConfig | description = desc }

                        newDevice =
                            { device | config = newDeviceConfig }

                        deviceEdits =
                            model.deviceEdits

                        newDeviceEdits =
                            { deviceEdits | device = Just newDevice }
                    in
                    ( { model | deviceEdits = newDeviceEdits }, Cmd.none )

        ProcessPortValue result ->
            case result of
                Ok portValue ->
                    processPortValue portValue model

                Err err ->
                    let
                        _ =
                            Debug.log "Port value decode error: " err
                    in
                    ( model, Cmd.none )

        SetTab tab ->
            ( { model | tab = tab }, Cmd.none )

        BLEScan ->
            ( model, PortCmd "scan" |> encodePortCmd |> portOut )

        BLEDisconnect ->
            ( model, PortCmd "disconnect" |> encodePortCmd |> portOut )

        SetGwWifiSSID ssid ->
            let
                gwConfigWifi =
                    model.gwConfigWifi

                gwConfigWifiNew =
                    { gwConfigWifi | wifiSSID = ssid }
            in
            ( { model | gwConfigWifi = gwConfigWifiNew }, Cmd.none )

        SetGwWifiPass pass ->
            let
                gwConfigWifi =
                    model.gwConfigWifi

                gwConfigWifiNew =
                    { gwConfigWifi | wifiPass = pass }
            in
            ( { model | gwConfigWifi = gwConfigWifiNew }, Cmd.none )

        GwWriteWifi ->
            ( model, model.gwConfigWifi |> encodeGwConfigWifi |> portOut )

        GwWriteTimer ->
            ( model, model.gwConfigTimer |> encodeGwConfigTimer |> portOut )

        GwFireTimer ->
            ( model, PortCmd "fireTimer" |> encodePortCmd |> portOut )

        GwSetTimerFireDuration fireDuration ->
            let
                gwConfigTimer =
                    model.gwConfigTimer

                fireDurationInt =
                    Maybe.withDefault 0 (String.toInt fireDuration)

                gwConfigTimerNew =
                    { gwConfigTimer | fireDuration = fireDurationInt }
            in
            ( { model | gwConfigTimer = gwConfigTimerNew }, Cmd.none )

        GwSetTimerFireTime fireTime ->
            let
                gwConfigTimer =
                    model.gwConfigTimer

                gwConfigTimerNew =
                    { gwConfigTimer | fireTime = fireTime }
            in
            ( { model | gwConfigTimer = gwConfigTimerNew }, Cmd.none )

        GotZone zone ->
            ( { model | timeZone = zone }, Cmd.none )


processPortValue : PortValue -> Model -> ( Model, Cmd Msg )
processPortValue portValue model =
    case portValue of
        GwStateValue state ->
            ( { model | gwState = state }, Cmd.none )



--    case portValue of
--PixelValue pix ->
-- View


viewDevices : Model -> Html Msg
viewDevices model =
    div []
        [ h1 [] [ text "Devices" ]
        , renderDevices model
        , renderEditDevice model.deviceEdits
        ]


viewTimer : Model -> Html Msg
viewTimer model =
    if model.gwState.bleConnected then
        div []
            [ h3 [] [ text "Configure Timer" ]
            , Form.group []
                [ Form.label [] [ text "Time of day to fire" ]
                , Input.text
                    [ Input.attrs
                        [ placeholder "enter time of day to fire"
                        , onInput GwSetTimerFireTime
                        , value model.gwConfigTimer.fireTime
                        , type_ "time"
                        ]
                    ]
                ]
            , Form.group []
                [ Form.label [] [ text "Fire duration (seconds)" ]
                , Input.text
                    [ Input.attrs
                        [ placeholder "enter time in seconds"
                        , onInput GwSetTimerFireDuration
                        , value (String.fromInt model.gwConfigTimer.fireDuration)
                        ]
                    ]
                ]
            , Button.button
                [ Button.outlinePrimary
                , Button.attrs [ onClick GwWriteTimer ]
                ]
                [ text "Save Timer Settings" ]
            , Button.button
                [ Button.outlinePrimary
                , Button.attrs [ onClick GwFireTimer ]
                ]
                [ text "Fire timer now" ]
            ]

    else
        text ""


posixTimeToString : Time.Zone -> Time.Posix -> String
posixTimeToString zone time =
    (String.padLeft 2 '0' <| String.fromInt <| Time.toHour zone time)
        ++ ":"
        ++ (String.padLeft 2 '0' <| String.fromInt <| Time.toMinute zone time)
        ++ ":"
        ++ (String.padLeft 2 '0' <| String.fromInt <| Time.toSecond zone time)


viewState : Model -> Html Msg
viewState model =
    let
        connected =
            if model.gwState.connected then
                "yes"

            else
                "no"

        timeDisplay =
            posixTimeToString model.timeZone (Time.millisToPosix (model.gwState.currentTime * 1000))

        hours =
            model.gwState.timerFireTime // 60

        min =
            model.gwState.timerFireTime - hours * 60

        timerFireTimeDisplay =
            (String.padLeft 2 '0' <| String.fromInt <| hours)
                ++ ":"
                ++ (String.padLeft 2 '0' <| String.fromInt <| min)
    in
    if model.gwState.bleConnected then
        div []
            [ h2 [] [ text "Device state:" ]
            , ul []
                [ li [] [ text ("Connected to portal: " ++ connected) ]
                , li [] [ text ("Model: " ++ model.gwState.model) ]
                , li [] [ text ("SSID: " ++ model.gwState.ssid) ]
                , li [] [ text ("Uptime: " ++ String.fromInt model.gwState.uptime) ]
                , li [] [ text ("Signal: " ++ String.fromInt model.gwState.signal) ]
                , li [] [ text ("Free Memory: " ++ String.fromInt model.gwState.freeMem) ]
                , li [] [ text ("Current time: " ++ timeDisplay) ]
                , li [] [ text ("Timer fire time: " ++ timerFireTimeDisplay) ]
                , li [] [ text ("Timer fire duration: " ++ String.fromInt model.gwState.timerFireDuration) ]
                ]
            , Button.button
                [ Button.outlineWarning
                , Button.attrs [ onClick BLEDisconnect ]
                ]
                [ text "Disconnect" ]
            ]

    else
        div []
            [ h2 [] [ text "not connected" ]
            , Button.button
                [ Button.outlinePrimary
                , Button.attrs [ onClick BLEScan ]
                ]
                [ text "Scan for device" ]
            ]


viewConfigure : Model -> Html Msg
viewConfigure model =
    div []
        [ viewState model
        , viewConfigWifi model
        , viewTimer model
        ]


viewConfigWifi : Model -> Html Msg
viewConfigWifi model =
    if model.gwState.bleConnected && model.gwState.model == "Argon" then
        div []
            [ h3 [] [ text "Configure Wifi" ]
            , Form.group []
                [ Form.label [] [ text "WiFi SSID" ]
                , Input.text
                    [ Input.attrs
                        [ placeholder "enter new SSID"
                        , onInput SetGwWifiSSID
                        , value model.gwConfigWifi.wifiSSID
                        ]
                    ]
                , Form.label [] [ text "WiFI Pass" ]
                , Input.text
                    [ Input.attrs
                        [ placeholder "enter new password"
                        , onInput SetGwWifiPass
                        , value model.gwConfigWifi.wifiPass
                        ]
                    ]
                ]
            , Button.button
                [ Button.outlinePrimary
                , Button.attrs [ onClick GwWriteWifi ]
                ]
                [ text "Save WiFi settings" ]
            ]

    else
        text ""


view : Model -> Browser.Document Msg
view model =
    let
        content =
            case model.tab of
                TabDevices ->
                    viewDevices model

                TabConfigure ->
                    viewConfigure model
    in
    { title = "Simple • IoT"
    , body =
        [ div []
            [ menu model
            , Grid.container []
                [ content
                ]
            ]
        ]
    }


menu : Model -> Html Msg
menu model =
    Navbar.config NavbarMsg
        |> Navbar.withAnimation
        |> Navbar.brand [ href "#" ] [ img [ src "/public/simple-iot-app-logo.png", width 83, height 25 ] [] ]
        |> Navbar.items
            [ Navbar.itemLink [ href "#", onClick (SetTab TabDevices) ] [ text "Devices" ]
            , Navbar.itemLink [ href "#", onClick (SetTab TabConfigure) ] [ text "Configure" ]
            ]
        |> Navbar.view model.navbarState


renderDevices : Model -> Html Msg
renderDevices model =
    Accordion.config AccordionMsg
        |> Accordion.withAnimation
        |> Accordion.cards
            (List.map
                renderDevice
                model.devices.devices
            )
        |> Accordion.view model.accordionState


renderDeviceSummary : Device -> String
renderDeviceSummary dev =
    dev.config.description ++ " (" ++ dev.id ++ ")"


renderDevice : Device -> Accordion.Card Msg
renderDevice dev =
    Accordion.card
        { id = dev.id
        , options = []
        , header =
            Accordion.header []
                (Accordion.toggle [] [ h4 [] [ text (renderDeviceSummary dev) ] ])
                |> Accordion.appendHeader
                    [ button
                        [ type_ "button"
                        , onClick (EditDevice dev.id)
                        , class "btn btn-light"
                        ]
                        [ edit Color.black 25 ]
                    ]
        , blocks = [ renderIos dev.state.ios ]
        }


renderIos : List Sample -> Accordion.CardBlock Msg
renderIos samples =
    Accordion.listGroup
        (List.map
            (\s -> ListGroup.li [] [ text (renderSample s) ])
            samples
        )


renderEditDevice : DeviceEdits -> Html Msg
renderEditDevice deviceEdits =
    case deviceEdits.device of
        Nothing ->
            Modal.config EditDeviceClose
                |> Modal.small
                |> Modal.h5 [] [ text "Warning!" ]
                |> Modal.body []
                    [ text "No device to edit" ]
                |> Modal.footer []
                    [ Button.button
                        [ Button.outlinePrimary
                        , Button.attrs [ onClick EditDeviceClose ]
                        ]
                        [ text "Cancel" ]
                    ]
                |> Modal.view deviceEdits.visibility

        Just device ->
            Modal.config EditDeviceClose
                |> Modal.h5 [] [ text ("Edit device (" ++ device.id ++ ")") ]
                |> Modal.body []
                    [ Form.group []
                        [ Form.label [] [ text "Device description" ]
                        , Input.text
                            [ Input.attrs
                                [ placeholder "enter description"
                                , onInput EditDeviceChangeDescription
                                , value device.config.description
                                ]
                            ]
                        ]
                    ]
                |> Modal.footer []
                    [ Button.button
                        [ Button.outlinePrimary
                        , Button.attrs [ onClick EditDeviceSave ]
                        ]
                        [ text "Save" ]
                    , Button.button
                        [ Button.outlineWarning
                        , Button.attrs [ onClick EditDeviceClose ]
                        ]
                        [ text "Cancel" ]
                    , Button.button
                        [ Button.outlineDanger
                        , Button.attrs [ onClick (EditDeviceDelete device.id) ]
                        ]
                        [ text "Delete" ]
                    ]
                |> Modal.view deviceEdits.visibility


type alias GwState =
    { model : String
    , connected : Bool
    , bleConnected : Bool
    , ssid : String
    , pass : String
    , uptime : Int
    , signal : Int
    , freeMem : Int
    , currentTime : Int
    , timerFireTime : Int
    , timerFireDuration : Int
    }


gwStateInit : GwState
gwStateInit =
    { model = "unknown"
    , connected = False
    , bleConnected = False
    , ssid = ""
    , pass = ""
    , uptime = -1
    , signal = -1
    , freeMem = -1
    , currentTime = 0
    , timerFireTime = 0
    , timerFireDuration = 0
    }


type PortValue
    = GwStateValue GwState


gwStateDecoder : Json.Decode.Decoder GwState
gwStateDecoder =
    Json.Decode.succeed GwState
        |> required "model" Json.Decode.string
        |> required "connected" Json.Decode.bool
        |> required "bleConnected" Json.Decode.bool
        |> required "ssid" Json.Decode.string
        |> required "pass" Json.Decode.string
        |> required "uptime" Json.Decode.int
        |> required "signal" Json.Decode.int
        |> required "freeMem" Json.Decode.int
        |> required "currentTime" Json.Decode.int
        |> required "timerFireTime" Json.Decode.int
        |> required "timerFireDuration" Json.Decode.int


portDecoder : Json.Decode.Decoder PortValue
portDecoder =
    Json.Decode.oneOf
        [ Json.Decode.map GwStateValue gwStateDecoder
        ]


portValueDecoder : Json.Decode.Value -> Result Json.Decode.Error PortValue
portValueDecoder v =
    Json.Decode.decodeValue portDecoder v
