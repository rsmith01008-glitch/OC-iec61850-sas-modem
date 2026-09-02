<?xml version="1.0" encoding="UTF-8"?>
<SCL version="2007" revision="B" release="4"
     xmlns="http://www.iec.ch/61850/2003/SCL"
     xmlns:oc="urn:oc-iec61850-sas:v1">
  <Header id="switchyard1-worked-example" version="1" toolID="oc-iec61850-sas-hand-authored">
    <Text>
      Minimal worked 1.5-breaker switchyard: 800kV/230kV, one power
      transformer, two 3-breaker diameters. See tools/scl-compiler/README.md
      and README.md's "SCL / Substation Configuration Language" section for
      how this compiles and what's functional vs descriptive-only.
    </Text>
  </Header>

  <Substation name="Switchyard1">
    <PowerTransformer name="XFMR1" type="PTR">
      <TransformerWinding name="HV" type="PTW">
        <Terminal connectivityNode="Switchyard1/V800/Diameter1/N2" cNodeName="N2"/>
        <TapChanger name="LTC1" type="LTC"/>
      </TransformerWinding>
      <TransformerWinding name="LV" type="PTW">
        <Terminal connectivityNode="Switchyard1/V230/Diameter2/N3" cNodeName="N3"/>
      </TransformerWinding>
    </PowerTransformer>

    <VoltageLevel name="V800">
      <Voltage unit="V" multiplier="k">800</Voltage>
      <Bay name="BusA800">
        <ConnectivityNode name="Bus" pathName="Switchyard1/V800/BusA800/Bus" desc="800kV Bus A"/>
      </Bay>
      <Bay name="BusB800">
        <ConnectivityNode name="Bus" pathName="Switchyard1/V800/BusB800/Bus" desc="800kV Bus B"/>
      </Bay>
      <Bay name="Diameter1" desc="Breaker-and-a-half diameter: Line1 tap (N1), Transformer HV tap (N2)">
      <ConductingEquipment name="CB1" type="CBR">
        <Terminal connectivityNode="Switchyard1/V800/BusA800/Bus" cNodeName="Bus"/>
        <Terminal connectivityNode="Switchyard1/V800/Diameter1/N1" cNodeName="N1"/>
      </ConductingEquipment>
      <ConductingEquipment name="CB2" type="CBR">
        <Terminal connectivityNode="Switchyard1/V800/Diameter1/N1" cNodeName="N1"/>
        <Terminal connectivityNode="Switchyard1/V800/Diameter1/N2" cNodeName="N2"/>
      </ConductingEquipment>
      <ConductingEquipment name="CB3" type="CBR">
        <Terminal connectivityNode="Switchyard1/V800/Diameter1/N2" cNodeName="N2"/>
        <Terminal connectivityNode="Switchyard1/V800/BusB800/Bus" cNodeName="Bus"/>
      </ConductingEquipment>
        <ConnectivityNode name="N1" pathName="Switchyard1/V800/Diameter1/N1" desc="Line1 tap"/>
        <ConnectivityNode name="N2" pathName="Switchyard1/V800/Diameter1/N2" desc="Transformer XFMR1 HV tap"/>
      </Bay>
    </VoltageLevel>

    <VoltageLevel name="V230">
      <Voltage unit="V" multiplier="k">230</Voltage>
      <Bay name="BusA230">
        <ConnectivityNode name="Bus" pathName="Switchyard1/V230/BusA230/Bus" desc="230kV Bus A"/>
      </Bay>
      <Bay name="BusB230">
        <ConnectivityNode name="Bus" pathName="Switchyard1/V230/BusB230/Bus" desc="230kV Bus B"/>
      </Bay>
      <Bay name="Diameter2" desc="Breaker-and-a-half diameter: Transformer LV tap (N3), Feed1 tap (N4)">
      <ConductingEquipment name="CB4" type="CBR">
        <Terminal connectivityNode="Switchyard1/V230/BusA230/Bus" cNodeName="Bus"/>
        <Terminal connectivityNode="Switchyard1/V230/Diameter2/N3" cNodeName="N3"/>
      </ConductingEquipment>
      <ConductingEquipment name="CB5" type="CBR">
        <Terminal connectivityNode="Switchyard1/V230/Diameter2/N3" cNodeName="N3"/>
        <Terminal connectivityNode="Switchyard1/V230/Diameter2/N4" cNodeName="N4"/>
      </ConductingEquipment>
      <ConductingEquipment name="CB6" type="CBR">
        <Terminal connectivityNode="Switchyard1/V230/Diameter2/N4" cNodeName="N4"/>
        <Terminal connectivityNode="Switchyard1/V230/BusB230/Bus" cNodeName="Bus"/>
      </ConductingEquipment>
        <ConnectivityNode name="N3" pathName="Switchyard1/V230/Diameter2/N3" desc="Transformer XFMR1 LV tap"/>
        <ConnectivityNode name="N4" pathName="Switchyard1/V230/Diameter2/N4" desc="Feed1 tap"/>
      </Bay>
    </VoltageLevel>
  </Substation>

  <Communication>
    <SubNetwork name="StationBus" type="8-MMS" desc="Shared GOOSE broadcast port + MMS-lite station LAN">
      <Private type="oc-iec61850-sas">
        <oc:transport goosePort="8104"/>
      </Private>
      <ConnectedAP iedName="CB1" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <Address>
            <P type="MAC-Address">01-0C-CD-01-00-01</P>
            <P type="APPID">0001</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">4</P>
          </Address>
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
      </ConnectedAP>
      <ConnectedAP iedName="CB2" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <Address>
            <P type="MAC-Address">01-0C-CD-01-00-02</P>
            <P type="APPID">0002</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">4</P>
          </Address>
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
      </ConnectedAP>
      <ConnectedAP iedName="CB3" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <Address>
            <P type="MAC-Address">01-0C-CD-01-00-03</P>
            <P type="APPID">0003</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">4</P>
          </Address>
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
      </ConnectedAP>
      <ConnectedAP iedName="CB4" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <Address>
            <P type="MAC-Address">01-0C-CD-01-00-04</P>
            <P type="APPID">0004</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">3</P>
          </Address>
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
      </ConnectedAP>
      <ConnectedAP iedName="CB5" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <Address>
            <P type="MAC-Address">01-0C-CD-01-00-05</P>
            <P type="APPID">0005</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">3</P>
          </Address>
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
      </ConnectedAP>
      <ConnectedAP iedName="CB6" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <Address>
            <P type="MAC-Address">01-0C-CD-01-00-06</P>
            <P type="APPID">0006</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">3</P>
          </Address>
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
      </ConnectedAP>
      <ConnectedAP iedName="XFMR1" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <Address>
            <P type="MAC-Address">01-0C-CD-01-00-20</P>
            <P type="APPID">0020</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">6</P>
          </Address>
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
        <SMV ldInst="LD0" cbName="svcXfmr1">
          <Address>
            <P type="MAC-Address">01-0C-CD-04-00-01</P>
            <P type="APPID">4001</P>
            <P type="VLAN-ID">000</P>
            <P type="VLAN-PRIORITY">6</P>
          </Address>
        </SMV>
      </ConnectedAP>
      <ConnectedAP iedName="SCADA1" apName="AP1"/>
    </SubNetwork>
  </Communication>

  <IED name="CB1">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>
              <oc:interlock id="CB1_VS_CB2" localRef="XCBR1.PosCtl" blockValue="closed"
                  peerIed="CB2" peerRef="XCBR1.Pos" condition="eq" peerValue="closed"/>
              <oc:ptocScheme name="PTOC1" input="MMXU1.Amp" trip="XCBR1.PosCtl"
                  pickup="1.2" curve="IEC_VERY_INVERSE" timeMultiplier="0.3"
                  resetSec="0.1" respectInterlocks="false"/>

            </Private>
            <DataSet name="dsGoose1">
              <FCDA lnClass="XCBR" lnInst="1" doName="Pos" fc="ST"/>
            </DataSet>
            <ReportControl name="rcbStatus1" datSet="dsGoose1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" datSet="dsGoose1" appID="CB1/gcbGoose1" type="GOOSE" securityEnable="None"/>
          </LN0>
          <LN prefix="" lnClass="XCBR" inst="1" lnType="XCBR_Basic">
            <DOI name="Pos">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0">
                  <oc:redstoneIo address="cb1-status-redstone" openSide="0" closedSide="1"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="PosCtl">
              <Private type="oc-iec61850-sas">
                <oc:point>
                  <oc:redstoneIo address="cb1-control-redstone" tripSide="2" closeSide="3" pulseMs="250" sboTimeoutSec="30"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="cb1-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="Vol">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="2.0">
                  <oc:meterIo address="cb1-voltmeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>
  <IED name="CB2">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>
              <oc:interlock id="CB2_VS_CB1" localRef="XCBR1.PosCtl" blockValue="closed"
                  peerIed="CB1" peerRef="XCBR1.Pos" condition="eq" peerValue="closed"/>
              <oc:ptocScheme name="PTOC1" input="MMXU1.Amp" trip="XCBR1.PosCtl"
                  pickup="1.2" curve="IEC_VERY_INVERSE" timeMultiplier="0.3"
                  resetSec="0.1" respectInterlocks="false"/>
              <oc:remoteTrip id="XFMR1_DIFF_TRIP" peerIed="XFMR1" peerRef="PDIF1.Op"
                  condition="eq" peerValue="true" localRef="XCBR1.PosCtl" tripValue="open"/>
            </Private>
            <DataSet name="dsGoose1">
              <FCDA lnClass="XCBR" lnInst="1" doName="Pos" fc="ST"/>
            </DataSet>
            <ReportControl name="rcbStatus1" datSet="dsGoose1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" datSet="dsGoose1" appID="CB2/gcbGoose1" type="GOOSE" securityEnable="None"/>
          </LN0>
          <LN prefix="" lnClass="XCBR" inst="1" lnType="XCBR_Basic">
            <DOI name="Pos">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0">
                  <oc:redstoneIo address="cb2-status-redstone" openSide="0" closedSide="1"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="PosCtl">
              <Private type="oc-iec61850-sas">
                <oc:point>
                  <oc:redstoneIo address="cb2-control-redstone" tripSide="2" closeSide="3" pulseMs="250" sboTimeoutSec="30"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="cb2-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="Vol">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="2.0">
                  <oc:meterIo address="cb2-voltmeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>
  <IED name="CB3">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>

              <oc:ptocScheme name="PTOC1" input="MMXU1.Amp" trip="XCBR1.PosCtl"
                  pickup="1.2" curve="IEC_VERY_INVERSE" timeMultiplier="0.3"
                  resetSec="0.1" respectInterlocks="false"/>
              <oc:remoteTrip id="XFMR1_DIFF_TRIP" peerIed="XFMR1" peerRef="PDIF1.Op"
                  condition="eq" peerValue="true" localRef="XCBR1.PosCtl" tripValue="open"/>
            </Private>
            <DataSet name="dsGoose1">
              <FCDA lnClass="XCBR" lnInst="1" doName="Pos" fc="ST"/>
            </DataSet>
            <ReportControl name="rcbStatus1" datSet="dsGoose1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" datSet="dsGoose1" appID="CB3/gcbGoose1" type="GOOSE" securityEnable="None"/>
          </LN0>
          <LN prefix="" lnClass="XCBR" inst="1" lnType="XCBR_Basic">
            <DOI name="Pos">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0">
                  <oc:redstoneIo address="cb3-status-redstone" openSide="0" closedSide="1"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="PosCtl">
              <Private type="oc-iec61850-sas">
                <oc:point>
                  <oc:redstoneIo address="cb3-control-redstone" tripSide="2" closeSide="3" pulseMs="250" sboTimeoutSec="30"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="cb3-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="Vol">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="2.0">
                  <oc:meterIo address="cb3-voltmeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>
  <IED name="CB4">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>
              <oc:interlock id="CB4_VS_CB5" localRef="XCBR1.PosCtl" blockValue="closed"
                  peerIed="CB5" peerRef="XCBR1.Pos" condition="eq" peerValue="closed"/>
              <oc:ptocScheme name="PTOC1" input="MMXU1.Amp" trip="XCBR1.PosCtl"
                  pickup="1.2" curve="IEC_VERY_INVERSE" timeMultiplier="0.3"
                  resetSec="0.1" respectInterlocks="false"/>
              <oc:remoteTrip id="XFMR1_DIFF_TRIP" peerIed="XFMR1" peerRef="PDIF1.Op"
                  condition="eq" peerValue="true" localRef="XCBR1.PosCtl" tripValue="open"/>
            </Private>
            <DataSet name="dsGoose1">
              <FCDA lnClass="XCBR" lnInst="1" doName="Pos" fc="ST"/>
            </DataSet>
            <ReportControl name="rcbStatus1" datSet="dsGoose1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" datSet="dsGoose1" appID="CB4/gcbGoose1" type="GOOSE" securityEnable="None"/>
          </LN0>
          <LN prefix="" lnClass="XCBR" inst="1" lnType="XCBR_Basic">
            <DOI name="Pos">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0">
                  <oc:redstoneIo address="cb4-status-redstone" openSide="0" closedSide="1"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="PosCtl">
              <Private type="oc-iec61850-sas">
                <oc:point>
                  <oc:redstoneIo address="cb4-control-redstone" tripSide="2" closeSide="3" pulseMs="250" sboTimeoutSec="30"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="cb4-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="Vol">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="2.0">
                  <oc:meterIo address="cb4-voltmeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>
  <IED name="CB5">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>
              <oc:interlock id="CB5_VS_CB4" localRef="XCBR1.PosCtl" blockValue="closed"
                  peerIed="CB4" peerRef="XCBR1.Pos" condition="eq" peerValue="closed"/>
              <oc:ptocScheme name="PTOC1" input="MMXU1.Amp" trip="XCBR1.PosCtl"
                  pickup="1.2" curve="IEC_VERY_INVERSE" timeMultiplier="0.3"
                  resetSec="0.1" respectInterlocks="false"/>
              <oc:remoteTrip id="XFMR1_DIFF_TRIP" peerIed="XFMR1" peerRef="PDIF1.Op"
                  condition="eq" peerValue="true" localRef="XCBR1.PosCtl" tripValue="open"/>
            </Private>
            <DataSet name="dsGoose1">
              <FCDA lnClass="XCBR" lnInst="1" doName="Pos" fc="ST"/>
            </DataSet>
            <ReportControl name="rcbStatus1" datSet="dsGoose1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" datSet="dsGoose1" appID="CB5/gcbGoose1" type="GOOSE" securityEnable="None"/>
          </LN0>
          <LN prefix="" lnClass="XCBR" inst="1" lnType="XCBR_Basic">
            <DOI name="Pos">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0">
                  <oc:redstoneIo address="cb5-status-redstone" openSide="0" closedSide="1"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="PosCtl">
              <Private type="oc-iec61850-sas">
                <oc:point>
                  <oc:redstoneIo address="cb5-control-redstone" tripSide="2" closeSide="3" pulseMs="250" sboTimeoutSec="30"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="cb5-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="Vol">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="2.0">
                  <oc:meterIo address="cb5-voltmeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>
  <IED name="CB6">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>

              <oc:ptocScheme name="PTOC1" input="MMXU1.Amp" trip="XCBR1.PosCtl"
                  pickup="1.2" curve="IEC_VERY_INVERSE" timeMultiplier="0.3"
                  resetSec="0.1" respectInterlocks="false"/>

            </Private>
            <DataSet name="dsGoose1">
              <FCDA lnClass="XCBR" lnInst="1" doName="Pos" fc="ST"/>
            </DataSet>
            <ReportControl name="rcbStatus1" datSet="dsGoose1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" datSet="dsGoose1" appID="CB6/gcbGoose1" type="GOOSE" securityEnable="None"/>
          </LN0>
          <LN prefix="" lnClass="XCBR" inst="1" lnType="XCBR_Basic">
            <DOI name="Pos">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0">
                  <oc:redstoneIo address="cb6-status-redstone" openSide="0" closedSide="1"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="PosCtl">
              <Private type="oc-iec61850-sas">
                <oc:point>
                  <oc:redstoneIo address="cb6-control-redstone" tripSide="2" closeSide="3" pulseMs="250" sboTimeoutSec="30"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="cb6-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="Vol">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="2.0">
                  <oc:meterIo address="cb6-voltmeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>

  <IED name="XFMR1" desc="Dedicated transformer differential-protection IED -- HV+LV CT meters, no breaker of its own; trips the 4 breakers bounding its taps (CB2/CB3 HV side, CB4/CB5 LV side) via remoteTrips[] on those IEDs">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>
              <oc:pdifScheme name="PDIF1" minPickup="0.2" restraintSlope="0.4" respectInterlocks="false">
                <oc:input ref="MMXU1.Amp" scale="1.0"/>
                <oc:input ref="MMXU2.Amp" scale="3.478"/>
              </oc:pdifScheme>
              <oc:pdisScheme name="PDIS1" zone1ReachOhms="12.5" zone1DelaySec="0" zone2ReachOhms="25" zone2DelaySec="0.3"/>
            </Private>
            <DataSet name="dsStatus1">
              <FCDA lnClass="MMXU" lnInst="1" doName="Amp" fc="MX"/>
              <FCDA lnClass="MMXU" lnInst="2" doName="Amp" fc="MX"/>
            </DataSet>
            <ReportControl name="rcbXfmr1" datSet="dsStatus1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" appID="XFMR1/gcbGoose1" type="GOOSE" securityEnable="None"/>
            <SampledValueControl name="svcXfmr1" smvID="XFMR1/svcXfmr1" smpRate="80" nofASDU="1" securityEnable="None">
              <SmvOpts/>
            </SampledValueControl>
          </LN0>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic" desc="HV-side CT">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="xfmr1-hv-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="2" lnType="MMXU_Basic" desc="LV-side CT">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="xfmr1-lv-ammeter-adapter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="RDRE" inst="1" lnType="RDRE_Basic"
              desc="Disturbance recorder -- data-model only, not wired to any event buffer (no oscillography capture implemented); see README Known Limitations"/>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>

  <IED name="SCADA1" type="SCADA">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" resyncSec="60" connectTimeoutSec="5"
                  reconnectIntervalSec="10" gooseStaleAfterSec="15" hmsPort="8103"/>
              <oc:historian dir="/var/log/sas-scada" maxBytes="262144" maxFiles="5"/>
              <oc:alarm id="V1_LOW" ref="CB1/LD0/MMXU1.Vol" condition="lt" value="720000"
                  severity="medium" message="800kV Bus A undervoltage at CB1"/>
              <oc:alarm id="XFMR1_DIFF_TRIP" ref="XFMR1/LD0/PDIF1.Op" condition="eq" value="true"
                  severity="critical" message="Transformer XFMR1 differential protection operated"/>
            </Private>
          </LN0>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>

  <DataTypeTemplates>
    <LNodeType id="LN0_Basic" lnClass="LLN0">
      <DO name="Mod" type="ENC_Basic"/>
    </LNodeType>
    <LNodeType id="XCBR_Basic" lnClass="XCBR">
      <DO name="Pos" type="DPS_Basic"/>
      <DO name="PosCtl" type="DPC_Basic"/>
    </LNodeType>
    <LNodeType id="MMXU_Basic" lnClass="MMXU">
      <DO name="Amp" type="MV_Basic"/>
      <DO name="Vol" type="MV_Basic"/>
    </LNodeType>
    <LNodeType id="RDRE_Basic" lnClass="RDRE">
      <DO name="RcdMade" type="ACT_Basic"/>
    </LNodeType>
    <DOType id="DPS_Basic" cdc="DPS">
      <DA name="stVal" fc="ST" bType="Dbpos"/>
    </DOType>
    <DOType id="DPC_Basic" cdc="DPC">
      <DA name="ctlVal" fc="CO" bType="Dbpos"/>
    </DOType>
    <DOType id="MV_Basic" cdc="MV">
      <DA name="mag" fc="MX" bType="FLOAT32"/>
    </DOType>
    <DOType id="ACT_Basic" cdc="ACT">
      <DA name="general" fc="ST" bType="BOOLEAN"/>
    </DOType>
    <DOType id="ENC_Basic" cdc="ENC">
      <DA name="stVal" fc="ST" bType="Enum" type="ModeKind"/>
    </DOType>
    <EnumType id="ModeKind">
      <EnumVal ord="1">on</EnumVal>
    </EnumType>
  </DataTypeTemplates>
</SCL>
